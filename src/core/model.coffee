if exports?
	cola = require("./entity")
	module?.exports = cola
else
	cola = @cola
#IMPORT_END

###
Model and Scope
###

cola.model = (name, model) ->
	if arguments.length is 2
		if model
			if cola.model.models[name]
				throw new cola.Exception("Duplicated model name \"#{name}\".")
			cola.model.models[name] = model
		else
			model = cola.removeModel(name)
		return model
	else
		return cola.model.models[name]

cola.model.models = {}

cola.removeModel = (name) ->
	model = cola.model.models[name]
	delete cola.model.models[name]
	return model

class cola.Scope
	get: (path, loadMode, context) ->
		return @data.get(path, loadMode, context)

	set: (path, data, context) ->
		@data.set(path, data, context)
		return @

	describe: (property, config) ->
		return @data.describe(property, config)

	dataType: (name) ->
		if typeof name is "string"
			dataType = @data.definition(name)
			return if dataType instanceof cola.DataType then dataType else null
		else if name
			if name instanceof Array
				for dataType in name
					if not (dataType instanceof cola.DataType)
						if dataType.lazy isnt false
							dataType = new cola.EntityDataType(dataType)
							if dataType.name
								@data.regDefinition(dataType.name, dataType)
			else
				dataType = name
				if not (dataType instanceof cola.DataType)
					if dataType.lazy isnt false
						dataType = new cola.EntityDataType(dataType)
						if dataType.name
							@data.regDefinition(dataType.name, dataType)
						return dataType
			return

	definition: (name) ->
		return @data.definition(name)

	flush: (name, loadMode) ->
		@data.flush(name, loadMode)
		return @

	disableObservers: () ->
		@data.disableObservers()
		return @

	enableObservers: () ->
		@data.enableObservers()
		return @

	notifyObservers: () ->
		@data.notifyObservers()
		return @

	watch: (path, fn) ->
		processor = {
			processMessage: (bindingPath, path, type, arg) ->
				fn(path, type, arg)
				return
		}
		if path instanceof Array
			for p in path
				@data.bind(p, processor)
		else
			@data.bind(path, processor)
		return @

	hasExBinding: () ->
		return @_hasExBinding

	setHasExBinding: (hasExBinding) ->
		return if @_hasExBinding is hasExBinding
		@_hasExBinding = hasExBinding
		@parent?.setHasExBinding(true) if hasExBinding
		return

class cola.Model extends cola.Scope
	constructor: (name, parent) ->
		cola.currentScope ?= @

		if name instanceof cola.Scope
			parent = name
			name = undefined

		if name
			@name = name
			cola.model(name, @)

		if parent and typeof parent is "string"
			parentName = parent
			parent = cola.model(parentName)

		@parent = parent
		@setHasExBinding(true)

		@data = new cola.DataModel(@)

		parent.data.bind("**", @) if parent

		@action = (name, action) ->
			store = @action
			if arguments.length is 1
				if typeof name is "string"
					scope = @
					while store
						fn = store[name]
						if fn
							return fn.action or fn
						scope = scope.parent
						break unless scope
						store = scope.action

					return cola.defaultAction[name]
				else if name and typeof name is "object"
					config = name
					for n, a of config
						@action(n, a)
				return null
			else
				if action
					store[name] = action
				else
					delete store[name]
				return @

	destroy: () ->
		cola.removeModel(@name) if @name
		@data.destroy?()
		return

	processMessage: (bindingPath, path, type, arg) ->
		return @data.onDataMessage(path, type, arg)

	$: (selector) ->
		@_$dom ?= $(@_dom)
		return @_$dom.find(selector)

class cola.SubScope extends cola.Scope

	watchPath: (path) ->
		return if @_watchAllMessages or @_watchPath is path

		@_unwatchPath()

		if path
			@_watchPath = paths = []
			parent = @parent
			if path instanceof Array
				for p in path
					p = p + ".**"
					paths.push(p)
					parent?.data.bind(p, @)
			else
				path = path + ".**"
				paths.push(path)
				parent?.data.bind(path, @)
		else
			delete @_watchPath
		return

	_unwatchPath: () ->
		return unless @_watchPath
		path = @_watchPath
		delete @_watchPath
		parent = @parent
		if parent and path
			if path instanceof Array
				for p in path
					parent.data.unbind(p, @)
			else
				parent.data.unbind(path, @)
		return

	watchAllMessages: () ->
		return if @_watchAllMessages
		@_watchAllMessages = true
		@_unwatchPath()
		parent = @parent
		if parent
			@_watchPath = ["**"]
			parent.data.bind("**", @)
			parent.watchAllMessages?()
		return

	destroy: () ->
		if @parent then @_unwatchPath()
		return


class cola.ExpressionScope extends cola.SubScope
	repeatNotification: true

	_unwatchPath: () ->
		super()
		if @parent and @expressionDynaPaths
			for path in @expressionDynaPaths
				@parent.data.unbind(path, @)
		return

	setExpression: (expression) ->
		@expression = expression
		@expressionPaths ?= []

		if expression
			if expression.paths
				for path in @expression.paths
					@expressionPaths.push(path.split("."))

			if not expression.paths and expression.hasCallStatement and not expression.hasDefinedPath
				@watchAllMessages()
			else
				@watchPath(expression.paths)
		else
			@_unwatchPath()
		return

	evaluate: (scope, dynaExpressionOnly, loadMode = "async", dataCtx = {}) ->
		return unless @expression

		if dynaExpressionOnly and @dynaExpression
			result = @dynaExpression.evaluate(scope, loadMode, dataCtx)
		else
			result = @expression.evaluate(scope, loadMode, dataCtx)

			if @expression.isDyna and dataCtx.dynaExpression
				@dynaExpression = dataCtx.dynaExpression
				if @dynaExpression.raw isnt @dynaExpressionStr
					@dynaExpressionStr = @dynaExpression.raw

				if @parent and not @ignoreBind
					if @expressionDynaPaths
						for path in @expressionDynaPaths
							@parent.data.unbind(path, @)
						delete @expressionDynaPaths

					paths = @expression.paths
					dynaPaths = @dynaExpression.paths
					if dynaPaths
						for path in dynaPaths
							if not paths or paths.indexOf(path) < 0
								if not @expressionDynaPaths
									@expressionDynaPaths = [path]
								else
									@expressionDynaPaths.push(path)
								@parent.data.bind(path, @)
		return result

	isParentOfTarget: (changedPath) ->
		expressionPaths = @expressionPaths
		expressionDynaPaths = @expressionDynaPaths

		if not expressionPaths.length and not expressionDynaPaths then return false
		if not changedPath then return true

		if expressionPaths.length
			for targetPath in expressionPaths
				isParent = true
				for part, i in changedPath
					targetPart = targetPath[i]
					if part isnt targetPart
						if targetPart is "**" then continue
						else if targetPart is "*"
							if i is changedPath.length - 1 then continue
						isParent = false
						break

				if isParent then return 2

		if expressionDynaPaths
			for targetPath in expressionDynaPaths
				isParent = true
				for part, i in changedPath
					targetPart = targetPath[i].split(".")
					if part isnt targetPart
						if targetPart is "**" then continue
						else if targetPart is "*"
							if i is changedPath.length - 1 then continue
						isParent = false
						break

				if isParent then return 1
		return 0

class cola.AliasScope extends cola.ExpressionScope

	constructor: (@parent, expression) ->
		@setExpression(expression)
		@data = new cola.AliasDataModel(@, expression.alias, @dataType)
		@action = @parent.action

	destroy: () ->
		super()
		@data.destroy()
		return

	setExpression: (expression) ->
		super(expression)
		if expression and typeof expression.paths.length is 1 and not expression.hasCallStatement
			@dataType = @parent.data.getDataType(expression.paths[0])
		return

	setTargetData: (data) ->
		@data.setTargetData(data)
		return

	retrieveData: (dynaExpressionOnly) ->
		cola.util.cancelDelay(@, "retrieve")

		data = @evaluate(@, dynaExpressionOnly)
		@setTargetData(data)
		return

	refreshTargetData: () ->
		@data.onDataMessage([@expression.alias], cola.constants.MESSAGE_REFRESH, {
			data: data
		})
		return

	processMessage: (bindingPath, path, type, arg) ->
		if @messageTimestamp >= arg.timestamp then return
		allProcessed = @_processMessage(bindingPath, path, type, arg)

		if not allProcessed
			@data.onDataMessage(path, type, arg)
		return

	_processMessage: (bindingPath, path, type, arg) ->
		if type is cola.constants.MESSAGE_REFRESH or type is cola.constants.MESSAGE_CURRENT_CHANGE or type is cola.constants.MESSAGE_PROPERTY_CHANGE or type is cola.constants.MESSAGE_REMOVE
			isParent = @isParentOfTarget(path)
			if isParent
				@retrieveData(isParent < 2)
				@refreshTargetData()
				allProcessed = true
			else if @expression
				if not @expressionPaths and @expression.hasCallStatement and not @expression.hasDefinedPath
					cola.util.delay(@, "retrieve", 100, () =>
						@retrieveData()
						@refreshTargetData()
						return
					)
					allProcessed = true
		return allProcessed

class cola.ItemScope extends cola.SubScope
	constructor: (@parent, alias) ->
		@data = new cola.ItemDataModel(@, alias, @parent?.dataType)
		@action = @parent.action

	watchPath: () ->

	watchAllMessages: () ->
		@parent?.watchAllMessages?()
		return

	processMessage: (bindingPath, path, type, arg) ->
		return @data.onDataMessage(path, type, arg)

class cola.ItemsScope extends cola.ExpressionScope

	constructor: (parent, expression) ->
		@setParent(parent)
		@setExpression(expression)

	setParent: (parent) ->
		if @parent then @_unwatchPath()

		@parent = parent
		@data = parent.data
		@action = parent.action

		if @_watchAllMessages
			@watchAllMessages()
		else if @_watchPath
			@watchPath(@_watchPath)
		return

	setExpression: (expression) ->
		super(expression)
		@alias = if expression then expression.alias else "item"
		return

	setItems: (items) ->
		@_setItems(items)
		return

	retrieveData: (dynaExpressionOnly) ->
		cola.util.cancelDelay(@, "retrieve")

		if @_retrieveItems
			 @_retrieveItems(dynaExpressionOnly)
		else if @expression
			items = @evaluate(@parent, dynaExpressionOnly)
			@setItems(items)
		return

	_setItems: (items) ->
		@items = items
		@originItems = if items instanceof Array then items.$origin else null
		return

	refreshItems: () ->
		@onItemsRefresh?()
		return

	refreshItem: (arg) ->
		arg.itemsScope = @
		@onItemRefresh?(arg)
		return

	insertItem: (arg) ->
		arg.itemsScope = @
		@onItemInsert?(arg)
		return

	removeItem: (arg) ->
		arg.itemsScope = @
		@onItemRemove?(arg)
		return

	itemsLoadingStart: (arg) ->
		arg.itemsScope = @
		@onItemsLoadingStart?(arg)

	itemsLoadingEnd: (arg) ->
		arg.itemsScope = @
		@onItemsLoadingEnd?(arg)

	changeCurrentItem: (arg) ->
		arg.itemsScope = @
		@onCurrentItemChange?(arg)
		return

	resetItemScopeMap: () ->
		@itemScopeMap = {}
		return

	getItemScope: (item) ->
		itemId = cola.Entity._getEntityId(item)
		return @itemScopeMap[itemId]

	regItemScope: (itemId, itemScope) ->
		@itemScopeMap[itemId] = itemScope
		return

	unregItemScope: (itemId) ->
		delete @itemScopeMap[itemId]
		return

	findItemDomBinding: (item) ->
		itemScopeMap = @itemScopeMap
		items = @items
		originItems = @originItems
		multiOriginItems = originItems?._multiItems
		if items or originItems
			while item
				if item instanceof cola.Entity
					matched = (item.parent is items)
					if !matched and originItems
						if multiOriginItems
							for oi in originItems
								if item.parent is oi
									matched = true
									break
						else
							matched = (item.parent is originItems)
					if matched
						itemId = cola.Entity._getEntityId(item)
						return if itemId then itemScopeMap[itemId] else null
				item = item.parent
		return null

	processMessage: (bindingPath, path, type, arg) ->
		if @messageTimestamp >= arg.timestamp then return
		allProcessed = @_processMessage(bindingPath, path, type, arg)

		if allProcessed
			@messageTimestamp = arg.timestamp
		else if @itemScopeMap
			itemScope = @findItemDomBinding(arg.data or arg.entity)
			if itemScope
				itemScope.processMessage(bindingPath, path, type, arg)
			else if @hasExBinding()
				for id, itemScope of @itemScopeMap
					if itemScope.hasExBinding()
						itemScope.processMessage(bindingPath, path, type, arg)
		return

	isOriginItems: (items) ->
		return false unless @originItems
		return true if @originItems is items

		if @originItems instanceof Array and @originItems._multiItems
			for originItems in @originItems
				if originItems is items
					return true
		return false

	_processMessage: (bindingPath, path, type, arg)->
		if type is cola.constants.MESSAGE_REFRESH
			if @isParentOfTarget(path, @expressionPaths)
				@retrieveData()
				@refreshItems()
				allProcessed = true
			else
				processMoreMessage = true

		else if type is cola.constants.MESSAGE_PROPERTY_CHANGE # or type is cola.constants.MESSAGE_STATE_CHANGE
			if @isParentOfTarget(path, @expressionPaths)
				@retrieveData()
				@refreshItems()
				allProcessed = true
			else
				parent = arg.entity?.parent
				if parent is @items or @isOriginItems(arg.parent)
					@refreshItem(arg)
				else
					processMoreMessage = true

		else if type is cola.constants.MESSAGE_CURRENT_CHANGE
			if arg.entityList is @items or @isOriginItems(arg.entityList)
				@onCurrentItemChange?(arg)
			else if @isParentOfTarget(path, @expressionPaths)
				@retrieveData()
				@refreshItems()
				allProcessed = true
			else
				processMoreMessage = true

		else if type is cola.constants.MESSAGE_INSERT
			if arg.entityList is @items
				@insertItem(arg)
				allProcessed = true
			else if @isOriginItems(arg.entityList)
				@insertItem(arg)
				allProcessed = true
			else
				processMoreMessage = true

		else if type is cola.constants.MESSAGE_REMOVE
			if arg.entityList is @items
				@removeItem(arg)
				allProcessed = true
			else if @isOriginItems(arg.entityList)
				items = @items
				if items instanceof Array
					i = items.indexOf(arg.entity)
					if i > -1 then items.splice(i, 1)
				@removeItem(arg)
				allProcessed = true
			else
				processMoreMessage = true

		else if type is cola.constants.MESSAGE_LOADING_START
			if @isParentOfTarget(path, @expressionPaths) then @itemsLoadingStart(arg)

		else if type is cola.constants.MESSAGE_LOADING_END
			if @isParentOfTarget(path, @expressionPaths) then @itemsLoadingEnd(arg)

		if processMoreMessage and @expression
			if not @expressionPaths and @expression.hasCallStatement and not @expression.hasDefinedPath
				cola.util.delay(@, "retrieve", 100, () =>
					@retrieveData()
					@refreshItems()
					return
				)
		return allProcessed

###
DataModel
###

class cola.AbstractDataModel
	disableObserverCount: 0

	constructor: (@model) ->

	get: (path, loadMode, context) ->
		if not path
			return @_getRootData() or @model.parent?.get()

		if @_aliasMap
			i = path.indexOf('.')
			firstPart = if i > 0 then path.substring(0, i) else path
			aliasHolder = @_aliasMap[firstPart]
			if aliasHolder
				aliasData = aliasHolder.data
				if i > 0
					if loadMode and (typeof loadMode is "function" or typeof loadMode is "object")
						loadMode = "async"
						callback = loadMode
					return cola.Entity._evalDataPath(aliasData, path.substring(i + 1), false, loadMode, callback,
						context)
				else
					return aliasData

		rootData = @_rootData
		if rootData?
			if @model.parent
				i = path.indexOf('.')
				if i > 0
					prop = path.substring(0, i)
				else
					prop = path

				if rootData.hasValue(prop)
					return rootData.get(path, loadMode, context)
				else
					return @model.parent.data.get(path, loadMode, context)
			else
				return rootData.get(path, loadMode, context)
		else
			return @model.parent?.data.get(path, loadMode, context)

	set: (path, data, context) ->
		if path
			rootData = @_getRootData()
			if typeof path is "string"
				i = path.indexOf('.')
				if i > 0
					firstPart = path.substring(0, i)
					if @_aliasMap
						aliasHolder = @_aliasMap[firstPart]
						if aliasHolder
							if aliasHolder.data
								cola.Entity._setValue(aliasHolder.data, path.substring(i + 1), data, context)
							else
								throw new cola.Exception("Cannot set value to \"#{path}\"")
							return @

					if @model.parent
						if rootData.hasValue(firstPart)
							rootData.set(path, data, context)
						else
							@model.parent.data.set(path, data, context)
					else
						rootData.set(path, data, context)
				else
					@_set(path, data, context)
			else
				data = path
				for p of data
					@set(p, data[p], context)
		return @

	_set: (prop, data, context) ->
		rootData = @_rootData
		hasValue = rootData.hasValue(prop)

		if @_aliasMap?[prop]
			oldAliasHolder = @_aliasMap[prop]
			if oldAliasHolder.data != data
				oldAliasData = oldAliasHolder.data
				delete @_aliasMap[prop]
				@unbind(oldAliasHolder.bindingPath, oldAliasHolder)

		if data? # 判断是数据还是数据声明
			if data.$provider or data.$dataType
				if data.$provider
					provider = new cola.Provider(data.$provider)

				rootDataType = rootData.dataType
				property = rootDataType.getProperty(prop)
				property ?= rootDataType.addProperty(property: prop)

				property.set("provider", provider) if provider
				property.set("dataType", data.$dataType) if data.$dataType

		if !provider or hasValue
			if data and (data instanceof cola.Entity or data instanceof cola.EntityList) and data.parent and data != rootData._data[prop] # is alias
				@_aliasMap ?= {}

				path = data.getPath("always")
				dataModel = @
				@_aliasMap[prop] = aliasHolder = {
					data: data
					path: path
					bindingPath: path.slice(0).concat("**")
					processMessage: (bindingPath, path, type, arg) ->
						relativePath = path.slice(@path.length)
						dataModel.onDataMessage([prop].concat(relativePath), type, arg)
						return
				}
				@bind(aliasHolder.bindingPath, aliasHolder)
				@onDataMessage([prop], cola.constants.MESSAGE_PROPERTY_CHANGE, {
					entity: rootData
					property: prop
					oldValue: oldAliasData
					value: data
				})
			else
				rootData.set(prop, data, context)
		return

	reset: (name) ->
		@_rootData?.reset(name)
		return @

	flush: (name, loadMode) ->
		@_rootData?.flush(name, loadMode)
		return @

	bind: (path, processor) ->
		if !@bindingRegistry
			@bindingRegistry =
				__path: ""
				__processorMap: {}

		if typeof path is "string"
			path = path.split(".")

		if path then @_bind(path, processor)
		return @

	_bind: (path, processor) ->
		node = @bindingRegistry
		if path
			for part in path
				subNode = node[part]
				if !subNode?
					nodePath = if !node.__path then part else (node.__path + "." + part)
					node[part] = subNode =
						__path: nodePath
						__processorMap: {}
				node = subNode

			processor.id ?= cola.uniqueId()
			node.__processorMap[processor.id] = processor
		return

	unbind: (path, processor) ->
		if !@bindingRegistry then return

		if typeof path is "string"
			path = path.split(".")

		if path then @_unbind(path, processor)
		return @

	_unbind: (path, processor) ->
		node = @bindingRegistry
		for part in path
			node = node[part]
			if not node? then break

		delete node.__processorMap[processor.id] if node?

	disableObservers: () ->
		if @disableObserverCount < 0 then @disableObserverCount = 1 else @disableObserverCount++
		return @

	enableObservers: () ->
		if @disableObserverCount < 1 then @disableObserverCount = 0 else @disableObserverCount--
		return @

	notifyObservers: () ->
		@_rootData?.notifyObservers()
		return @

	onDataMessage: (path, type, arg = {}) ->
		return unless @bindingRegistry
		return if @disableObserverCount > 0

		oldScope = cola.currentScope
		cola.currentScope = @
		try
			arg.timestamp ?= cola.sequenceNo()
			if path
				node = @bindingRegistry
				lastIndex = path.length - 1
				for part, i in path
					if i is lastIndex then anyPropNode = node["*"]
					@processDataMessage(anyPropNode, path, type, arg) if anyPropNode
					anyChildNode = node["**"]
					@processDataMessage(anyChildNode, path, type, arg) if anyChildNode

					node = node[part]
					break unless node
			else
				node = @bindingRegistry
				anyPropNode = node["*"]
				@processDataMessage(anyPropNode, null, type, arg) if anyPropNode
				anyChildNode = node["**"]
				@processDataMessage(anyChildNode, null, type, arg) if anyChildNode

			@processDataMessage(node, path, type, arg, true) if node
		finally
			cola.currentScope = oldScope
		return

	processDataMessage: (node, path, type, arg, notifyChildren) ->
		processorMap = node.__processorMap
		for id, processor of processorMap
			if !processor.disabled and (!(processor.timestamp >= arg.timestamp) or processor.repeatNotification)
				processor.timestamp = arg.timestamp
				processor.processMessage(node.__path, path, type, arg)

		if notifyChildren
			notifyChildren2 = not (cola.constants.MESSAGE_EDITING_STATE_CHANGE <= type <= cola.constants.MESSAGE_VALIDATION_STATE_CHANGE) and not (cola.constants.MESSAGE_LOADING_START <= type <= cola.constants.MESSAGE_LOADING_END)

			if type is cola.constants.MESSAGE_CURRENT_CHANGE
				type = cola.constants.MESSAGE_REFRESH

			for part, subNode of node
				if subNode and (part is "**" or notifyChildren2) and part != "__processorMap" and part != "__path"
					@processDataMessage(subNode, path, type, arg, true)
		return

class cola.DataModel extends cola.AbstractDataModel

	_createRootData: (rootDataType) ->
		return new cola.Entity(null, rootDataType)

	_getRootData: () ->
		if not @_rootData?
			@_rootDataType ?= new cola.EntityDataType()
			@_rootData = rootData = @_createRootData(@_rootDataType)
			rootData.state = cola.Entity.STATE_NEW
			dataModel = @
			rootData._setDataModel(dataModel)
		return @_rootData

	describe: (property, config) ->
		@_getRootData()
		if typeof property is "string"
			propertyDef = @_rootDataType?.getProperty(property)
			if config
				if not propertyDef
					propertyDef = @_rootDataType.addProperty(property: property)

				if typeof config is "string"
					dataType = @definition(config)
					if not dataType
						throw new cola.Exception("Unrecognized DataType \"#{config}\".")
					propertyDef.set("dataType", dataType)
				else if config instanceof cola.DataType
					propertyDef.set("dataType", config)
				else
					propertyDef.set(config)
		else if property
			config = property
			for propertyName, propertyConfig of config
				@describe(propertyName, propertyConfig)
		return

	getProperty: (path) ->
		i = path.indexOf(".")
		if i > 0
			path1 = path.substring(0, i)
			path2 = path.substring(i + 1)
		else
			path1 = null
			path2 = path

		dataModel = @
		while dataModel
			rootDataType = dataModel._rootDataType
			if rootDataType
				if path1
					dataType = rootDataType.getProperty(path1)?.get("dataType")
				else
					dataType = rootDataType
				if dataType then break
			dataModel = dataModel.model.parent?.data

		return dataType?.getProperty(path2)

	getDataType: (path) ->
		property = @getProperty(path)
		dataType = property?.get("dataType")
		return dataType

	definition: (name) ->
		definition = @_definitionStore?[name]
		if definition
			if not (definition instanceof cola.Definition)
				definition = new cola.EntityDataType(definition)
				@_definitionStore[name] = definition
		else
			definition = cola.DataType.defaultDataTypes[name]
		return definition

	regDefinition: (name, definition) ->
		if name instanceof cola.Definition
			definition = name
			name = name._name

		if not name
			throw new cola.Exception("Attribute \"name\" cannot be emtpy.")

		if definition._scope and definition._scope != @model
			throw new cola.Exception("DataType(#{definition._name}) is already belongs to anthor Model.")

		store = @_definitionStore
		if !store?
			@_definitionStore = store = {}
		else if store[name]
			throw new cola.Exception("Duplicated Definition name \"#{name}\".")

		store[name] = definition
		return @

	unregDefinition: (name) ->
		if @_definitionStore
			definition = @_definitionStore[name]
			delete @_definitionStore[name]
		return definition

	addEntityListener: (listener) ->
		@_entityListeners ?= []
		@_entityListeners.push(listener)
		return

	removeEntityListener: (listener) ->
		return unless @_entityListeners
		if listener
			i = @_entityListeners.indexOf(listener)
			if i > -1
				@_entityListeners.splice(i, 1)
		return

	onEntityAttach: (entity) ->
		if @_entityListeners
			for listener in  @_entityListeners
				listener.onEntityAttach(entity)
		return

	onEntityDetach: (entity) ->
		if @_entityListeners
			for listener in  @_entityListeners
				listener.onEntityDetach(entity)
		return

class cola.AliasDataModel extends cola.AbstractDataModel
	constructor: (@model, @alias, @dataType) ->
		@defaultDataType = @dataType
		parentModel = @model.parent
		while parentModel
			if parentModel.data
				@parent = parentModel.data
				break
			parentModel = parentModel.parent

	getTargetData: () ->
		return @_targetData

	setTargetData: (data, silence) ->
		oldData = @_targetData
		@_targetData = data

		if data instanceof cola.Entity or data instanceof cola.EntityList
			@dataType = data.dataType or @defaultDataType

		if not silence
			@onDataMessage([@alias], cola.constants.MESSAGE_PROPERTY_CHANGE, {
				entity: null
				property: @alias
				value: data
				oldValue: oldData
			})
		return

	describe: (property, config) ->
		if property is @alias
			return super(property, config)
		else
			return @parent.describe(property, config)

	getProperty: (path) ->
		i = path.indexOf(".")
		if i > 0
			if path.substring(0, i) is @alias
				dataType = if @_targetData instanceof cola.Entity or @_targetData instanceof cola.EntityList then @_targetData.dataType else null
				if dataType
					property = dataType.getProperty(path.substring(i + 1))
					dataType = property?.get("dataType")
				return dataType
			else
				return @parent.getDataType(path)
		else if path is @alias
			return if @_targetData instanceof cola.Entity or @_targetData instanceof cola.EntityList then @_targetData.dataType else null
		else
			return @parent.getProperty(path)

	getDataType: (path) ->
		i = path.indexOf(".")
		if i > 0
			if path.substring(0, i) is @alias
				if @_rootDataType
					property = @_rootDataType?.getProperty(path.substring(i + 1))
					dataType = property?.get("dataType")
				return dataType
			else
				return @parent.getDataType(path)
		else if path is @alias
			return @dataType
		else
			return @parent.getDataType(path)

	definition: (name) ->
		return @parent.definition(name)

	regDefinition: (definition) ->
		return @parent.regDefinition(definition)

	unregDefinition: (definition) ->
		return @parent.unregDefinition(definition)

	_bind: (path, processor) ->
		super(path, processor)

		if not @_exBindingProcessed and path[0] isnt @alias
			@_exBindingProcessed = true
			@model.setHasExBinding(true)
			@model.watchAllMessages()
		return

	get: (path, loadMode, context) ->
		alias = @alias
		aliasLen = alias.length
		if path.substring(0, aliasLen) is alias
			c = path.charCodeAt(aliasLen)
			if c is 46 # `.`
				if path.indexOf(".") > 0
					targetData = @_targetData
					if targetData instanceof cola.Entity
						return targetData.get(path.substring(aliasLen + 1), loadMode, context)
					else if targetData and typeof targetData is "object"
						return targetData[path.substring(aliasLen + 1)]
			else if isNaN(c)
				return @_targetData
		return @parent.get(path, loadMode, context)

	set: (path, data, context) ->
		alias = @alias
		aliasLen = alias.length
		if path.substring(0, aliasLen) is alias
			c = path.charCodeAt(aliasLen)
			if c is 46 # `.`
				if path.indexOf(".") > 0
					@_targetData?.set(path.substring(aliasLen + 1), data, context)
					return @
			else if isNaN(c)
				@setTargetData(data)
				return @
		@parent.set(path, data, context)
		return @

	dataType: (path) ->
		return @parent.dataType(path)

	regDefinition: (name, definition) ->
		@parent.regDefinition(name, definition)
		return @

	unregDefinition: (name) ->
		return @parent.unregDefinition(name)

	flush: (path, loadMode) ->
		alias = @alias
		if path.substring(0, alias.length) is alias
			c = path.charCodeAt(1)
			if c is 46 # `.`
				@_targetData?.flush(path.substring(alias.length + 1), loadMode)
				return @
			else if isNaN(c)
				@_targetData?.flush(loadMode)
				return @
		@parent.flush(path, loadMode)
		return @

	disableObservers: () ->
		@parent.disableObservers()
		return @

	enableObservers: () ->
		@parent.enableObservers()
		return @

	notifyObservers: () ->
		@parent.notifyObservers()
		return @

	onDataMessage: (path, type, arg) ->
		super(path, type, arg)

		if @_targetData
			targetData = @_targetData
			entity = arg.data or arg.entityList or arg.entity
			while entity
				if entity is targetData
					isChild = true
					break
				entity = entity.parent

			if isChild
				relativePath = path.slice(targetData.getPath().length)
				super([@alias].concat(relativePath), type, arg)
		return

class cola.ItemDataModel extends cola.AliasDataModel

	getIndex: () -> @_index
	setIndex: (index, silence) ->
		@_index = index
		if !silence
			@onDataMessage([cola.constants.REPEAT_INDEX], cola.constants.MESSAGE_PROPERTY_CHANGE, {
				entity: null
				property: cola.constants.REPEAT_INDEX
				value: index
			})
		return

	get: (path, loadMode, context) ->
		if path is cola.constants.REPEAT_INDEX
			return @getIndex()
		else
			return super(path, loadMode, context)

	set: (path, data, context) ->
		if path is cola.constants.REPEAT_INDEX
			@setIndex(data)
		else
			super(path, data, context)
		return

###
Root Model
###
new cola.Model(cola.constants.DEFAULT_PATH)

###
Function
###

cola.data = (config) ->
	return config unless config
	if config.provider
		provider = config.provider
	else
		provider = {}
		for k, v of config
			if k != "dataType"
				provider[k] = v

	dataType = config.dataType
	if dataType
		if typeof dataType is "string"
			name = dataType
			dataType = cola.currentScope.dataType(name)
			if !dataType
				throw new cola.Exception("Unrecognized DataType \"#{name}\".")
		else if not (dataType instanceof cola.DataType)
			dataType = new cola.EntityDataType(dataType)

	return {
		$dataType: dataType
		$provider: provider
	}

###
Element binding
###

class cola.ElementAttrBinding
	constructor: (@element, @attr, @expression, scope) ->
		@scope = scope
		@paths = @expression.paths or []
		@watchingMoreMessage = not @paths.length and @expression.hasCallStatement and not @expression.hasDefinedPath

		for path in @paths
			scope.data.bind(path, @)

	destroy: () ->
		paths = @paths
		if paths
			for path in paths
				@scope.data.unbind(path, @)
		return

	processMessage: (bindingPath, path, type)->
		if cola.constants.MESSAGE_REFRESH <= type <= cola.constants.MESSAGE_CURRENT_CHANGE or @watchingMoreMessage
			@refresh(@dynaPaths?.indexOf(bindingPath) >= 0)
		return

	evaluate: (dynaExpressionOnly, dataCtx) ->
		loadMode = "async"
		if dynaExpressionOnly and @dynaExpression
			result = @dynaExpression.evaluate(@scope, loadMode, dataCtx)
		else
			result = @expression.evaluate(@scope, loadMode, dataCtx)

			if @expression.isDyna and dataCtx?.dynaExpression
				dynaExpression = dataCtx.dynaExpression
				if dynaExpression.raw isnt @dynaExpressionStr
					@dynaExpressionStr = dynaExpression.raw

				if not @ignoreBind
					if @dynaPaths
						for path in @dynaPaths
							@scope.data.unbind(path, @)

					paths = @dynaExpression.paths
					if paths
						for path in paths
							if @paths.indexOf(path) < 0
								if not @dynaPaths
									@dynaPaths = [path]
								else
									@dynaPaths.push(path)
								@scope.data.bind(path, @)
		return result

	_refresh: (dynaExpressionOnly) ->
		value = @evaluate(dynaExpressionOnly)
		element = @element
		element._duringBindingRefresh = true
		try
			element.set(@attr, value)
		finally
			element._duringBindingRefresh = false
		return

	refresh: (dynaExpressionOnly) ->
		return unless @_refresh
		if @delay
			cola.util.delay(@, "refresh", 100, () ->
				@_refresh(dynaExpressionOnly)
				return
			)
		else
			@_refresh(dynaExpressionOnly)
		return

cola.submit = (options, callback) ->
	originalOptions = options
	options = {}
	options[p] = v for p, v of originalOptions

	data = options.data
	if data
		if !(data instanceof cola.Entity or data instanceof cola.EntityList)
			throw new cola.Exception("Invalid submit data.")

		if @dataFilter
			filter = cola.submit.filter[@dataFilter]
			data = if filter then filter(data) else data

	if data or options.alwaysSubmit
		if options.parameter
			options.data =
				data: data
				parameter: options.parameter
		else
			options.data = data
		jQuery.post(options.url, options.data).done((result)->
			cola.callback(callback, true, result)
			return
		).fail((result)->
			cola.callback(callback, true, result)
			return
		)
		return true
	else
		return false

cola.submit.filter =
	"dirty": (data) ->
		if data instanceof cola.EntityList
			filtered = []
			data.each (entity) ->
				if entity.state != cola.Entity.STATE_NONE
					filtered.push(entity)
				return
		else if data.state != cola.Entity.STATE_NONE
			filtered = data
		return filtered

	"child-dirty": (data) ->
		return data

	"dirty-tree": (data) ->
		return data