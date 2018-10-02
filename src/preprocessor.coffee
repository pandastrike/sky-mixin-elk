# Panda Sky Mixin: Elasticsearch
# This mixin allocates the requested Elasticsearch cluster into your CloudFormation stack.
import {resolve} from "path"
import {cat, isObject, merge, values, capitalize, camelCase, plainText, difference} from "panda-parchment"
import Sundog from "sundog"

process = (SDK, config) ->
  sundog = Sundog SDK
  s3 = sundog.AWS.S3()

  # Start by extracting out the KMS Mixin configuration:
  {env, tags=[]} = config
  c = config.aws.environments[env].mixins.elk
  c = if isObject c then c else {}
  c.tags = cat (c.tags || []), tags
  c.tags.push {Key: "subtask", Value: "logging"}

  # This mixin only works with a VPC
  if !config.aws.vpc
    throw new Error "The Elasticsearch mixin can only be used in environments featuring a VPC."

  # Elasticsearch cluster configuration... by default only use one subnet.
  cluster =
    domain: config.environmentVariables.fullName + "-elk"
    subnets: ['"Fn::Select": [ 0, "Fn::Split": [ ",", {Ref: Subnets} ]]']
  if c.cluster.nodes?.highAvailability
    cluster.subnets.push '"Fn::Select": [1, "Fn::Split": [ ",", {Ref: Subnets} ]]'
  cluster = merge cluster, c.cluster

  # Kinesis firehose configuration
  stream = {
    name: config.environmentVariables.fullName + "-elk"
    bucket: "#{config.environmentVariables.fullName}-elk-firehose-backup"
    lambda:
      bucket: config.environmentVariables.skyBucket
      key: "mixin-code/elk/package.zip"
      name: "#{config.environmentVariables.fullName}-elk-firehose-transform"
  }
  
  stream.lambda.arn = "arn:aws:lambda:#{config.aws.region}:#{config.accountID}:function:#{stream.lambda.name}"

  # Check if we need to make a bucket for the stream's failure dumps.
  if !(await s3.bucketExists stream.bucket)
    stream.newBucket = true

  # Upload the processing lambda to the main orchestration bucket
  await s3.bucketTouch stream.lambda.bucket
  await s3.put stream.lambda.bucket, stream.lambda.key, (resolve __dirname, "..", "..", "..", "files", "package.zip"), false


  # Go through the lambdas producing log outputs and prepare their log names for the subscription filters.
  logs = []
  cloudfrontFormat = (str) ->
    str = str[config.environmentVariables.fullName.length...]
    capitalize camelCase plainText str
  if config.resources
    for resource in values config.resources
      for method in values resource.methods
        log = name: "/aws/lambda/#{method.lambda.function.name}"
        log.templateName = cloudfrontFormat method.lambda.function.name
        logs.push log
  else if config.environment?.simulations
    for simulation in values config.environment.simulations
      log = name: "/aws/lambda/#{simulation.lambda.function.name}"
      log.templateName = cloudfrontFormat method.lambda.function.name
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
