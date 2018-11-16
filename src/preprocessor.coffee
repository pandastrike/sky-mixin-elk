# Panda Sky Mixin: Elasticsearch
# This mixin allocates the requested Elasticsearch cluster into your CloudFormation stack.
import {resolve} from "path"
import {cat, isObject, merge, values, capitalize, camelCase, plainText, difference} from "panda-parchment"
import Sundog from "sundog"

process = (SDK, config) ->
  sundog = Sundog SDK
  s3 = sundog.AWS.S3()
  Log = sundog.AWS.CloudWatchLogs()

  # Start by extracting out the KMS Mixin configuration:
  {env, tags=[]} = config
  c = config.aws.environments[env].mixins.elk
  c = if isObject c then c else {}
  c.tags = cat (c.tags || []), tags
  c.tags.push {Key: "subtask", Value: "logging"}

  # This mixin only works with a VPC
  # if !config.aws.vpc
  #   throw new Error "The Elasticsearch mixin can only be used in environments featuring a VPC."

  # Elasticsearch cluster configuration... by default only use one subnet.
  cluster =
    domain: config.environmentVariables.fullName + "-elk"
  #   subnets: ['"Fn::Select": [ 0, "Fn::Split": [ ",", {Ref: Subnets} ]]']
  # if c.cluster.nodes?.highAvailability
  #   cluster.subnets.push '"Fn::Select": [1, "Fn::Split": [ ",", {Ref: Subnets} ]]'
  cluster = merge cluster, c.cluster
  if !cluster.nodes
    cluster.nodes =
      count: 1
      type: "t2.medium.elasticsearch"
      highAvailability: false
  if !cluster.nodes.highAvailability
    cluster.nodes.highAvailability = false

  # Kinesis stream configuration
  stream = {
    name: config.environmentVariables.fullName + "-elk"
    lambda:
      bucket: config.environmentVariables.skyBucket || config.environmentVariables.starBucket
      key: "mixin-code/elk/package.zip"
      name: "#{config.environmentVariables.fullName}-elk-transform"
  }

  stream.lambda.arn = "arn:aws:lambda:#{config.aws.region}:#{config.accountID}:function:#{stream.lambda.name}"

  # Upload the processing lambda to the main orchestration bucket
  await s3.bucketTouch stream.lambda.bucket
  await s3.put stream.lambda.bucket, stream.lambda.key, (resolve __dirname, "..", "..", "..", "files", "package.zip"), false


  # Go through the lambdas producing log outputs and prepare their log names for the subscription filters.
  logs = []
  cloudformationFormat = (str) ->
    str = str[config.environmentVariables.fullName.length...]
    capitalize camelCase plainText str
  if config.resources
    for resource in values config.resources
      for method in values resource.methods
        name = "/aws/lambda/#{method.lambda.function.name}"
        if !(await Log.exists name)
          await Log.create name

        log = {name}
        log.templateName = cloudformationFormat method.lambda.function.name
        logs.push log
  else if config.environment?.simulations
    for simulation in values config.environment.simulations
      log = name: "/aws/lambda/#{simulation.lambda.function.name}"
      log.templateName = cloudformationFormat simulation.lambda.function.name
      logs.push log
  else
    throw new Error "Unable to find Sky resources or Stardust simulations to name lambda log groups."

  {
    cluster
    stream
    logs
    tags: c.tags,
    accountID: config.accountID
    region: config.aws.region
  }

export default process
