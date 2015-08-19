express = require('express')
http = require("http")
Settings = require('settings-sharelatex')
logger = require('logger-sharelatex')
logger.initialize("documentupdater")
RedisManager = require('./app/js/RedisManager')
UpdateManager = require('./app/js/UpdateManager')
DispatchManager = require('./app/js/DispatchManager')
Keys = require('./app/js/RedisKeyBuilder')
Errors = require "./app/js/Errors"
HttpController = require "./app/js/HttpController"

redis = require("redis-sharelatex")
rclient = redis.createClient(Settings.redis.web)


Path = require "path"
Metrics = require "metrics-sharelatex"
Metrics.initialize("doc-updater")
Metrics.mongodb.monitor(Path.resolve(__dirname + "/node_modules/mongojs/node_modules/mongodb"), logger)

app = express()
app.configure ->
	app.use(Metrics.http.monitor(logger));
	app.use express.bodyParser()
	app.use app.router

rclient.subscribe("pending-updates")
rclient.on "message", (channel, doc_key) ->
	[project_id, doc_id] = Keys.splitProjectIdAndDocId(doc_key)
	if !Settings.shuttingDown
		UpdateManager.processOutstandingUpdatesWithLock project_id, doc_id, (error) ->
			logger.error err: error, project_id: project_id, doc_id: doc_id, "error processing update" if error?
	else
		logger.log project_id: project_id, doc_id: doc_id, "ignoring incoming update"

DispatchManager.createAndStartDispatchers(Settings.dispatcherCount || 10)

UpdateManager.resumeProcessing()

app.get    '/project/:project_id/doc/:doc_id',       HttpController.getDoc
app.post   '/project/:project_id/doc/:doc_id',       HttpController.setDoc
app.post   '/project/:project_id/doc/:doc_id/flush', HttpController.flushDocIfLoaded
app.delete '/project/:project_id/doc/:doc_id',       HttpController.flushAndDeleteDoc
app.delete '/project/:project_id',                   HttpController.deleteProject
app.post   '/project/:project_id/flush',             HttpController.flushProject

app.get '/total', (req, res)->
	timer = new Metrics.Timer("http.allDocList")	
	RedisManager.getCountOfDocsInMemory (err, count)->
		timer.done()
		res.send {total:count}
	
app.get '/status', (req, res)->
	if Settings.shuttingDown
		res.send 503 # Service unavailable
	else
		res.send('document updater is alive')


redisCheck = require("redis-sharelatex").activeHealthCheckRedis(Settings.redis.web)
app.get "/health_check/redis", (req, res, next)->
	if redisCheck.isAlive()
		res.send 200
	else
		res.send 500


app.use (error, req, res, next) ->
	logger.error err: error, "request errored"
	if error instanceof Errors.NotFoundError
		res.send 404
	else
		res.send(500, "Oops, something went wrong")

module.exports = {app:app}
