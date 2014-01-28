{_} = require 'lodash'

# api
exports.initialize = (schema, callback) ->
  # convert schema.settings to valid nano url:
  # http[s]://[username:password@]host[:port][/database]
  unless schema.settings.url
    schema.settings.url = "http" + (if schema.settings.ssl then "s" else "") + "://"
    if schema.settings.username and schema.settings.password
      schema.settings.url += schema.settings.username + ":" + schema.settings.password + "@"
    schema.settings.url += schema.settings.host
    if schema.settings.port
      schema.settings.url += ":" + schema.settings.port
    if schema.settings.database
      schema.settings.url += "/" + schema.settings.database

  throw new Error 'url is missing' unless opts = schema.settings
  db = require('nano')(opts)

  schema.adapter = new NanoAdapter db
  design = views: by_model: map:
    'function (doc) { if (doc.model) return emit(doc.model, null); }'

  helpers.updateDesign db, '_design/nano', design, callback

class NanoAdapter
  constructor: (@db) ->
    @_models = {}

  define: (descr) =>
    descr.properties._rev = type: String
    modelName = descr.model.modelName
    # Add index views for schemas that have indexes
    design =
      views: {}
    hasIndexes = false
    for propName, value of descr.properties
      if value.index
        hasIndexes = true
        viewName = helpers.viewName propName
        design.views[viewName] =
          map: 'function (doc) { if (doc.model && doc.model === \'' + modelName + '\' && doc.' + propName + ') return emit(doc.' + propName + ', null); }'
    if hasIndexes
      designName = '_design/' + helpers.designName modelName
      helpers.updateDesign this.db, designName, design

    @_models[modelName] = descr

  create: (args...) => @save args...

  save: (model, data, callback) =>
    data.model = @table model
    helpers.savePrep data

    @db.insert @forDB(model, data), (err, doc) =>
      return callback err if err
      # Undo the effects of savePrep as data object is the only one
      # that the JugglingDb model can access.
      helpers.undoPrep data
      # Update the data object with the revision returned by CouchDb.
      data._rev = doc.rev
      # This callback makes no sense in the context of JugglingDb invocation
      # but I'm leaving it as-is for other possible use cases.
      callback null, doc.id, doc.rev #doc.id, doc.rev

  updateOrCreate: (model, data = {}, callback) =>
    @exists model, data.id, (err, exists) =>
      return callback err if err
      return @save model, data, callback if exists

      @create model, data, (err, id) ->
        return callback err if err
        data.id = id
        callback null, data

  exists: (model, id, callback) =>
    @db.head id, (err, _, headers) ->
      return callback null, no if err
      callback null, headers?

  find: (model, id, callback) =>
    @db.get id, (err, doc) =>
      return callback null, null if err and err.status_code is 404
      return callback err if err
      callback null, @fromDB(model, doc)

  destroy: (model, id, callback) =>
    @db.get id, (err, doc) =>
      return callback err if err
      @db.destroy id, doc._rev, (err, doc) =>
        return callback err if err
        callback.removed = yes
        callback null

  updateAttributes: (model, id, data, callback) =>
    @db.get id, (err, base) =>
      return callback err if err
      @save model, helpers.merge(base, data), callback

  count: (model, callback, where) =>
    @all model, {where}, (err, docs) =>
      return callback err if err
      callback null, docs.length

  destroyAll: (model, callback) =>
    @all model, {}, (err, docs) =>
      return callback err if err
      docs = for doc in docs
        {_id: doc.id, _rev: doc._rev, _deleted: yes}
      @db.bulk {docs}, callback

  forDB: (model, data = {}) =>
    props = @_models[model].properties
    for k, v of props
      if data[k] and props[k].type.name is 'Date' and data[k].getTime?
        data[k] = data[k].getTime()
    data

  fromDB: (model, data) =>
    return data unless data
    props = @_models[model].properties
    for k, v of props
      if data[k]? and props[k].type.name is 'Date'
        date = new Date data[k]
        date.setTime data[k]
        data[k] = date
    data

  all: (model, filter, callback) =>
    params =
      keys: [@table model]
      include_docs: yes

    # We always fallback on nano/by_model view as it allows us
    # to iterate over all the docs for a model. But check if
    # there is a specialized view for one of the where conditions.
    designName = 'nano'
    viewName = 'by_model'
    if where = filter?.where
      props = @_models[model].properties
      for propName, value of where
        # We can use an optimal view when a where "clause" uses an indexed property
        if value and props[propName]? and props[propName].index
          # Use the design and view for the model and propName
          designName = helpers.designName model
          viewName = helpers.viewName propName
          # CouchDb stores dates as Unix time
          params.key = if _.isDate value then value.getTime() else value
          # We don't want to use keys - we now have a key property
          delete params.keys
          # We don't want to use this where clause as it's done on the server-side through the use of view
          # This is safe even though we are iterating over where as we are breaking below.
          delete filter.where[propName]
          # If all the filtering is done on the server-side we can now remove the entire where
          delete filter.where if _.isEmpty(filter.where)
          # We can only use one view so we assume that one is as good as the other
          # (which may not be true as one may have less docs referenced in it but we
          # cannot know in advance)
          break

    # Client-side processing has to be done when we are doing ordering and filtering (where).
    # If there was any matching view we are already using it.
    doClientSideProcessing = not filter or filter.order or filter.where
    # When doing client-side processing we can't use CouchDb's skip and limit.
    # TODO: Consider issuing performance warnings for larger datasets (e.g. row count > 1,000)
    # TODO: When doing no-limit query we should split the workload into smaller chunks.
    if not doClientSideProcessing
      params.skip = filter.offset if filter.offset
      params.limit = filter.limit if filter.limit

    @db.view designName, viewName, params, (err, body) =>
      return callback err if err

      docs = for row in body.rows
        row.doc.id = row.doc._id
        delete row.doc._id
        row.doc

      if doClientSideProcessing
        if where = filter?.where
          for k, v of where
            # CouchDb stores dates as Unix time
            where[k] = v.getTime() if _.isDate v
          docs = _.where docs, where

        if orders = filter?.order
          orders = [orders] if _.isString orders

          sorting = (a, b) ->
            for item, i in @
              ak = a[@[i].key]; bk = b[@[i].key]; rev = @[i].reverse
              if ak > bk then return 1 * rev
              if ak < bk then return -1 * rev
            0

          for key, i in orders
            orders[i] =
              reverse: helpers.reverse key
              key: helpers.stripOrder key

          docs.sort sorting.bind orders

        if doClientSideProcessing
          if filter?.offset
            docs = docs.slice(filter.offset)

          if filter?.limit
            docs = docs.slice(0, filter.limit)

      return callback null, (@fromDB model, doc for doc in docs)

  defineForeignKey: (model, key, callback) =>
    callback null, String

  defineProperty: (model, prop, params) =>
    @_models[model].properties[prop] = params

  table: (model) =>
    @_models[model].model.tableName

# helpers
helpers =
  merge: (base, update) ->
    return update unless base
    base[k] = update[k] for k, v of update
    base
  reverse: (key) ->
    if hasOrder = key.match(/\s+(A|DE)SC$/i)
      return -1 if hasOrder[1] is "DE"
    1
  stripOrder: (key) ->
    key.replace(/\s+(A|DE)SC/i, "")
  savePrep: (data) ->
    if id = data.id
      data._id = id.toString()
    delete data.id
    if data._rev is null
      delete data._rev
  undoPrep: (data) ->
    if _id = data._id
      data.id = _id.toString()
    delete data._id
    return
  designName: (modelName) ->
    'nano-' + modelName
  viewName: (propName) ->
    'by_' + propName
  invokeCallbackOrLogError: (callback, err, res) ->
    # When callback exists let it handle the error and result
    if callback
      callback err, res
    else if err
      # Without a callback we can at least log the error
      console.log err
  updateDesign: (db, designName, design, callback) ->
    # Add the design document to the database or update it if it already exists.
    db.get designName, (err, designDoc) =>
      if err && err.error != 'not_found'
        helpers.invokeCallbackOrLogError callback, err, designDoc
        return

      # Update the design doc
      if !designDoc
        designDoc = design
      else
        # We only update the design when its views have changed - this avoids rebuilding the views.
        if _.isEqual(designDoc.views, design.views)
          helpers.invokeCallbackOrLogError callback, null, designDoc
          return
        designDoc.views = design.views

      # Insert the design doc into the database.
      db.insert designDoc, designName, (err, insertedDoc) =>
        helpers.invokeCallbackOrLogError callback, err, insertedDoc
