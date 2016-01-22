_         = require 'lodash'
async     = require 'async'
colors    = require 'colors'
commander = require 'commander'
moment    = require 'moment'
request   = require 'request'
url       = require 'url'

QUERY = require './query.json'
packageJSON = require './package.json'

class Command
  parseOptions: =>
    commander
      .version packageJSON.version
      .option '-c, --capture-range <15>', 'capture range in minutes (env: FLOW_ETL_CAPTURE_RANGE_IN_MINUTES)'
      .option '-d, --destination-url <url>', 'destination elasticsearch url (env: FLOW_ETL_DESTINATION_ELASTICSEARCH_URL)'
      .option '-i, --interval <60>', 'interval in which to run, in seconds. (env: FLOW_ETL_INTERVAL)'
      .option '--single-run', 'only run for one cycle (env: FLOW_ETL_SINGLE_RUN)'
      .option '-s, --source-url <url>', 'source elasticsearch url (env: FLOW_ETL_SOURCE_ELASTICSEARCH_URL)'
      .parse process.argv

    @captureRangeInMinutes = parseInt(commander.captureRange ? process.env.FLOW_ETL_CAPTURE_RANGE_IN_MINUTES ? 15)
    @destinationElasticsearchUrl = commander.destinationUrl ? process.env.FLOW_ETL_DESTINATION_ELASTICSEARCH_URL
    @interval  = parseInt(commander.interval ? process.env.FLOW_ETL_INTERVAL || 60)
    @singleRun = commander.singleRun || (process.env.FLOW_ETL_SINGLE_RUN == 'true')
    @sourceElasticsearchUrl = commander.sourceUrl ? process.env.FLOW_ETL_SOURCE_ELASTICSEARCH_URL

    unless @destinationElasticsearchUrl? && @sourceElasticsearchUrl?
      commander.outputHelp()
      console.error colors.red '  destination-url is required' unless @destinationElasticsearchUrl?
      console.error colors.red '  source url-is required' unless @sourceElasticsearchUrl?
      process.exit 1

  run: =>
    @parseOptions()
    return @doSingleRun @tentativePanic if @singleRun
    @doForeverRun()

  doForeverRun: =>
    setInterval @doSingleRunOrDie, (1000 * 60 * @interval)

  doSingleRun: (callback) =>
    @search @query(), (error, result) =>
      return callback error if error?

      deployments = @process @normalize result
      async.each deployments, @update, callback

  doSingleRunOrDie: =>
    @doSingleRun (error) =>
      @panic error if error?

  query: =>
    return QUERY unless @captureRangeInMinutes?

    captureSince = moment().subtract parseInt(@captureRangeInMinutes), 'minutes'

    query = _.cloneDeep QUERY
    query.aggs.flowStart.filter.and.push({
      range:
        _timestamp:
          gte: captureSince
    })

    return query

  panic: (error) =>
    throw error
    process.exit 1

  tentativePanic: (error) =>
    @panic error if error?
    process.exit 0

  update: (deployment, callback) =>
    uri = url.format
      protocol: 'http'
      host: @destinationElasticsearchUrl
      pathname: "/flow_deploy_history/event/#{deployment.deploymentUuid}"

    request.put uri, json: deployment, (error, response, body) =>
      return callback error if error?
      return callback new Error(JSON.stringify body) if response.statusCode >= 300
      callback null

  search: (body, callback=->) =>
    options =
      baseUrl: @sourceElasticsearchUrl
      uri: '/device_status_flow/event/_search'
      json: body

    request.post options, (error, response, body) =>
      return callback error if error?
      if response.statusCode > 299
        return callback new Error("Bad response code from upstream server: #{response.statusCode}, body: #{body}")
      callback null, body

  normalize: (result) =>
    buckets = result.aggregations.flowStart.group_by_deploymentUuid.buckets
    _.map buckets, (bucket) =>
      {
        deploymentUuid: bucket.key
        beginTime: bucket.beginRecord.beginTime.value
        endTime:   bucket.endRecord.endTime.value
        workflow: 'flow-start'
        'app-octoblu':
          'beginTime': bucket['app-octoblu'].beginRecord.beginTime.value
          'endTime':   bucket['app-octoblu'].endRecord.endTime.value
        'api-octoblu':
          'beginTime': bucket['api-octoblu'].beginRecord.beginTime.value
          'endTime':   bucket['api-octoblu'].endRecord.endTime.value
        'flow-deploy-service':
          'beginTime': bucket['flow-deploy-service'].beginRecord.beginTime.value
          'endTime':   bucket['flow-deploy-service'].endRecord.endTime.value
        'flow-runner':
          'beginTime': bucket['flow-runner'].beginRecord.beginTime.value
          'endTime':   bucket['flow-runner'].endRecord.endTime.value
      }

  process: (deployments) =>
    _.map deployments, (deployment) =>
      {workflow, deploymentUuid, beginTime, endTime} = deployment

      formattedBeginTime = null
      formattedBeginTime = moment(beginTime).toISOString() if beginTime?
      formattedEndTime = null
      formattedEndTime = moment(endTime).toISOString() if endTime?

      elapsedTime = null
      elapsedTime = endTime - beginTime if beginTime? && endTime?

      {
        deploymentUuid: deploymentUuid
        workflow: workflow
        beginTime: formattedBeginTime
        endTime: formattedEndTime
        elapsedTime: elapsedTime
        success: endTime?
        'app-octoblu':         @extractStep beginTime, deployment['app-octoblu']
        'api-octoblu':         @extractStep beginTime, deployment['api-octoblu']
        'flow-deploy-service': @extractStep beginTime, deployment['flow-deploy-service']
        'flow-runner':         @extractStep beginTime, deployment['flow-runner']
      }

  extractStep: (beginTime, step) =>
    beginOffset = null
    beginOffset = step.beginTime - beginTime if step.beginTime?

    elapsedTime = null
    elapsedTime = step.endTime - step.beginTime if step.endTime? && step.beginTime?

    {
      beginOffset: beginOffset
      elapsedTime: elapsedTime
    }


command = new Command()
command.run()
