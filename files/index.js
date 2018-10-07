"use strict";

Object.defineProperty(exports, "__esModule", {
  value: true
});
exports.handler = undefined;

var _https = require("https");

var _https2 = _interopRequireDefault(_https);

var _url = require("url");

var _url2 = _interopRequireDefault(_url);

var _zlib = require("zlib");

var _zlib2 = _interopRequireDefault(_zlib);

function _interopRequireDefault(obj) { return obj && obj.__esModule ? obj : { default: obj }; }

// Generated by CoffeeScript 2.3.2

/*
Adapted from the "LogsToElasticsearch" Node 4.3 code produced by the Console during manual configurations.  This accepts compressed CloudWatch log data from a subscriber, parses it, and uploads N JSON documents to the Elasticsearch domain in question.
*/
var buildDoc, buildRequest, handler, merge, parseRegular, parseReport, parseResponse, post, transform, unzip;

merge = function (...objects) {
  return Object.assign({}, ...objects);
};

unzip = function (input) {
  return new Promise(function (resolve, reject) {
    return _zlib2.default.gunzip(input, function (error, buffer) {
      if (error) {
        return reject(error);
      } else {
        return resolve(buffer);
      }
    });
  });
};

parseReport = function (message) {
  return {
    requestId: RegExp("^REPORT RequestId\: (.*?)\t").exec(message)[1],
    duration: RegExp("\tDuration: (.*?) ms\t").exec(message)[1],
    memory: RegExp("\tMax Memory Used: (.*?) MB\t").exec(message)[1]
  };
};

parseRegular = function (message) {
  return {
    requestId: RegExp("^(.*?)\t(.*?)\t").exec(message)[2]
  };
};

buildDoc = function (handler, {
  id,
  timestamp,
  message
}) {
  var doc;
  doc = {
    id,
    handler,
    timestamp
  };

  if (RegExp("^REPORT").test(message)) {
    return merge(doc, parseReport(message));
  } else {
    return merge(doc, parseRegular(message));
  }
};

transform = function (payload) {
  var bulkRequestBody, handler;
  bulkRequestBody = "";
  handler = payload.logGroup.slice(12);
  payload.logEvents.forEach(function (logEvent) {
    var action, doc;
    doc = buildDoc(handler, logEvent);
    action = {
      index: {
        _index: process.env.indexName,
        _type: process.env.indexType,
        _id: logEvent.id
      }
    };
    return bulkRequestBody += [JSON.stringify(action), JSON.stringify(doc).replace(/\\n/g, "")].join('\n') + "\n";
  });
  return bulkRequestBody;
};

buildRequest = function (body) {
  var headers;
  headers = {
    "Content-Type": "application/json",
    "Host": process.env.endpoint,
    "Content-Length": Buffer.byteLength(body)
  };
  return {
    hostname: process.env.endpoint,
    method: "POST",
    path: "/_bulk",
    body,
    headers
  };
};

post = function (body) {
  var requestParams, responseBody;
  responseBody = "";
  requestParams = buildRequest(body);
  return new Promise(function (resolve, reject) {
    var request;
    request = _https2.default.request(requestParams, function (response) {
      response.on('data', function (chunk) {
        return responseBody += chunk;
      });
      return response.on('end', function () {
        var error, failedItems, info, success;
        info = JSON.parse(responseBody);

        if (Object.keys(info).length === 1 && info.Message) {
          throw new Error(info.Message);
        }

        if (response.statusCode >= 200 && response.statusCode < 299) {
          failedItems = info.items.filter(function (x) {
            return x.index.status >= 300;
          });
        }

        success = {
          attemptedItems: info.items.length,
          successfulItems: info.items.length - failedItems.length,
          failedItems: failedItems.length
        };
        error = response.statusCode !== 200 || info.errors === true ? {
          statusCode: response.statusCode,
          responseBody: responseBody
        } : null;
        return resolve({
          error,
          success,
          statusCode: response.statusCode,
          failedItems
        });
      });
    }).on('error', function (e) {
      return reject(e);
    });
    return request.end(requestParams.body);
  });
};

parseResponse = function (callback, {
  error,
  success,
  statusCode,
  failedItems
}) {
  console.log(`Response: ${JSON.stringify({
    statusCode
  })}`);

  if (error) {
    console.log(`Error: ${JSON.stringify(error, null, 2)}`);

    if ((failedItems != null ? failedItems.length : void 0) > 0) {
      console.log(`Failed Items: ${JSON.stringify(failedItems, null, 2)}`);
    }

    return callback(JSON.stringify(error));
  } else {
    console.log(`Success: ${JSON.stringify(success)}`);
    return callback(null, "Success");
  }
};

exports.handler = handler = async function ({
  Records
}, context, callback) {
  var awsLogsData, buffer, documents, e, esBulkBody, r, response, zippedInput;

  try {
    documents = await async function () {
      var i, len, results;
      results = [];

      for (i = 0, len = Records.length; i < len; i++) {
        r = Records[i]; // decode input from base64

        zippedInput = Buffer.from(r.kinesis.data, "base64"); // decompress the input

        buffer = await unzip(zippedInput); // parse the input from JSON

        awsLogsData = JSON.parse(buffer.toString()); // skip control messages

        if (awsLogsData.messageType === 'CONTROL_MESSAGE') {
          console.log("Received a control message.");
          continue;
        } else {
          results.push(transform(awsLogsData));
        }
      }

      return results;
    }(); // transform the input to Elasticsearch documents

    if (documents.length === 0) {
      return callback(null, "Successfully handled control message.");
    }

    esBulkBody = documents.join(""); // post documents to the Amazon Elasticsearch Service

    response = await post(esBulkBody);
    return parseResponse(callback, response);
  } catch (error1) {
    e = error1;
    console.log("Log transform failure", e.stack);
    return callback(e.message);
  }
};

exports.handler = handler;