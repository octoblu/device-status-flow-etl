_ = require 'lodash'
url = require 'url'
async = require 'async'
moment = require 'moment'
request = require 'request'
ElasticSearch = require 'elasticsearch'

QUERY = require './query.json'

class Command
  constructor: ->
    sourceElasticsearchUrl       = process.env.SOURCE_ELASTICSEARCH_URL ? 'localhost:9200'
    @destinationElasticsearchUrl = process.env.DESTINATION_ELASTICSEARCH_URL ? 'localhost:9200'
    @captureRangeInMinutes = process.env.CAPTURE_RANGE_IN_MINUTES

    @sourceElasticsearch      = new ElasticSearch.Client host: sourceElasticsearchUrl

  run: =>
    @search @query(), (error, result) =>
      throw error if error?

      deployments = @process @normalize result
      async.each deployments, @update, (error) =>
        throw error if error?
        process.exit 0

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
    @sourceElasticsearch.search({
      index: 'device_status_flow'
      type:  'event'
      search_type: 'count'
      body:  body
    }, callback)

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
