import macros
import strutils
import parseutils
import strformat, strutils
import asyncdispatch
import strscans
import options
import dimscord
import tables
import sequtils
import segfaults
import dimscmd/[
    macroUtils,
    commandOptions,
    scanner
]

# TODO, learn to write better documentation
## Commands are registered using with the .command. pragma or the .slashcommand. pragma.
## The .command. pragma is used for creating commands that the bot responds to in chat.
## The .slashcommand. pragma is used for creating commands that the bot responds to when using slash commands.
##
## If you are using slash commands then you must register the commands.
## This is done in your bots onReady event like so.
##
## ..code-block ::
##    proc onReady (s: Shard, r: Ready) {.event(discord).} =
##        await discord.api.registerCommands("742010764302221334") # You must pass your application ID which is found on your bots dashboard
##        echo "Ready as " & $r.user
##
## An issue with pragmas is that you cannot have optional parameters (or I am not smart enough to know how) and so this library uses the
## doc string of a procedure to provide further config. These are called doc options and are used like so
##
## .. code-block::
##    proc procThatYouWantToProvideOptionsFor() {.command.} =
##        ## $name: value # Variable must start with $
##        discard    


type
    CommandType* = enum
        ## A chat command is a command that is sent to the bot over chat
        ## A slash command is a command that is sent using the slash commands functionality in discord
        ctChatCommand
        ctSlashCommand
    
    ChatCommandProc = proc (m: Message): Future[void] # The message variable is exposed has `msg`
    SlashCommandProc = proc (i: Interaction): Future[void] # The Interaction variable is exposed has `i`

    Command = object
        name: string
        description: string
        parameters: seq[ProcParameter]
        guildID: string
        case kind: CommandType
            of ctSlashCommand:
                slashHandler: SlashCommandProc
            of ctChatCommand:
                chatHandler: ChatCommandProc
                discard
    
    CommandHandler = ref object
        discord: DiscordClient
        applicationID: string # Needed for slash commands
        msgVariable: string
        # TODO move from a table to a tree like structure. It will allow the user to declare command groups if they are in a tree
        chatCommands: Table[string, Command]
        slashCommands: Table[string, Command]

proc newHandler*(discord: DiscordClient, msgVariable: string = "msg"): CommandHandler =
    ## Creates a new handler which you can add commands to
    return CommandHandler(discord: discord, msgVariable: msgVariable)

proc getScannerCall*(parameter: ProcParameter, scanner: NimNode, getInner = false): NimNode =
    ## Gets the symbol that strscan uses in order to parse something of a certain type
    # Parse the string until it encounters the first [ or gets to the end
    # If there is still more to parse the slice the string until the second last character
    let procName = case parameter.kind:
        of "channel", "guildchannel": "nextChannel"
        of "user": "nextUser"
        of "role": "nextRole"
        of "int": "nextInt"
        of "string": "nextString"
        of "bool": "nextBool"
        else: ""
    if not parameter.sequence or getInner:
        result = newCall(procName, scanner)
    else:
        var innerCall = getScannerCall(parameter, scanner, true)
        if innerCall[0] == "await".ident: # vomit emoji TODO do better
            innerCall[0] = innerCall[1][0]
        result = newCall("nextSeq".ident, scanner, innerCall[0])

    if parameter.kind in ["channel", "user", "role"]:
        result = nnkCommand.newTree("await".ident, result)

proc addChatParameterParseCode(prc: NimNode, name: string, parameters: seq[ProcParameter], msgName: NimNode, router: NimNode): NimNode =
    ## **INTERNAL**
    ## This injects code to the start of a block of code which will parse cmdInput and set the variables for the different parameters
    ## Currently it only supports int and string parameter types
    ## This is achieved with the strscans module
    
    if len(parameters) == 0: return prc # Don't inject code if there is nothing to scan
    result = newStmtList()
    let scannerIdent = genSym(kind = nskLet, ident = "scanner")
    # Start the scanner and skip past the command
    result.add quote do:
        let `scannerIdent` = `router`.discord.api.newScanner(`msgName`)
        `scannerIdent`.skipPast(`name`)

    for parameter in parameters:
        if parameter.kind == "message": continue
        let ident = parameter.name.ident()
        let scanCall = getScannerCall(parameter, scannerIdent)
        result.add quote do:
            let `ident` = `scanCall`

    result = quote do:
        try:
            `result`
            `prc`
        except ScannerError as e:
            let msgParts = ($e.msg).split("(-)")
            when defined(debug) and not defined(testing):
                echo e.msg
            discard await `router`.discord.api.sendMessage(`msgName`.channelID, msgParts[0])

proc addInteractionParameterParseCode(prc: NimNode, name: string, parameters: seq[ProcParameter], iName: NimNode, router: NimNode): NimNode =
    ## **INTERNAL**
    ## Adds code into the proc body to get all the variables
    result = newStmtList()
    for parameter in parameters:
        let ident = parameter.name.ident()
        let paramName = parameter.name
        var
            outer: string
            inner: string
        # Parse the string until it encounters the first [ or gets to the end
        # If there is still more to parse the slice the string until the second last character
        let attributeName = case parameter.kind:
            of "int": "ival"
            of "bool": "bval"
            of "string": "str"
            else: raise newException(ValueError, parameter.kind & " is not supported")
        let attributeIdent = attributeName.ident()
        if parameter.optional:
           result.add quote do:
               let `ident` = `iName`.data.get().options[`paramName`].`attributeIdent`
        else:
            result.add quote do:
                let `ident` = `iName`.data.get().options[`paramName`].`attributeIdent`.get()
    result.add prc


proc register*(router: CommandHandler, name: string, handler: ChatCommandProc) =
    router.chatCommands[name].chatHandler = handler


proc register*(router: CommandHandler, name: string, handler: SlashCommandProc) =
    router.slashCommands[name].slashHandler = handler

proc generateHelpMessage*(router: CommandHandler): Embed =
    ## Generates the help message for all the chat commands
    result.title = some "Help"
    result.fields = some newSeq[EmbedField]()
    result.description = some "Commands"
    for command in router.chatCommands.values:
        var body = command.description & ": "
        for parameter in command.parameters:
            body &= fmt"<{parameter.name}> "
        result.fields.get().add EmbedField(
            name: command.name,
            value: body,
            inline: some true
        )


proc addCommand(router: NimNode, name: string, handler: NimNode, kind: CommandType): NimNode =
    handler.expectKind(nnkDo)
    # Create variables for optional parameters
    var
        guildID: NimNode = newStrLitNode("") # NimNode is used instead of string so that variables can be used
    
    var handlerBody = handler.body.copy() # Create a copy that can be edited without ruining the value that we are looping over
    for index, node in handler[^1].pairs():
        # TODO Remove this and change it to a pragma system or something
        if node.kind == nnkCommentStmt: continue # Ignore comments
        if node.kind == nnkCall:
            if node[0].kind != nnkIdent: break # If it doesn't contain an identifier then it isn't a config option
            case node[0].strVal.toLowerAscii() # Get the ident node
                of "guildid":
                    guildID = node[1][0]
                else:
                    # Extra parameters should be declared directly before or after the doc comment
                    break
            handlerBody.del(index)
                
   
    let 
        procName = newIdentNode(name & "Command") # The name of the proc that is returned is the commands name followed by "Command"
        description = handler.getDoc()
        cmdVariable = genSym(kind = nskVar, ident = "command")
    if kind == ctSlashCommand:
        doAssert description.len != 0, "Slash commands must have a description"
    result = newStmtList()
    
    result.add quote do:
            var `cmdVariable` = Command(
                name: `name`,
                description: `description`,
                guildID: `guildID`,
                kind: CommandType(`kind`)
            )

    # Default proc parameter names for msg and interaction            
    var 
        msgVariable = "msg".ident()
        interactionVariable = "i".ident()

    #
    # Get all the parameters that the command has and check whether it will get parsed from the message or it is it the message
    # itself
    #
    var parameters: seq[ProcParameter]
    for parameter in handler.getParameters():
        # Check the kind to see if it can be used has an alternate variable for the Message or Interaction
        case parameter.kind:
            of "message":
                msgVariable = parameter.name.ident()
            of "interaction":
                interactionVariable = parameter.name.ident()
            else:
                parameters &= parameter
                result.add quote do:
                    `cmdVariable`.parameters &= `parameter`
    # TODO remove code duplication?
    case kind:
        of ctChatCommand:
            let body = handlerBody.addChatParameterParseCode(name, parameters, msgVariable, router)
            result.add quote do:
                proc `procName`(`msgVariable`: Message) {.async.} =
                    `body`

                `cmdVariable`.chatHandler = `procName`
                `router`.chatCommands[`name`] = `cmdVariable`

        of ctSlashCommand:
            let body = handlerBody.addInteractionParameterParseCode(name, parameters, interactionVariable, router)
            result.add quote do:
                proc `procName`(`interactionVariable`: Interaction) {.async.} =
                    `body`
                `cmdVariable`.slashHandler = `procName` 
                `router`.slashCommands[`name`] = `cmdVariable`

macro addChat*(router: CommandHandler, name: static[string], handler: untyped): untyped =
    ## Add a new chat command to the handler
    ## A chat command is a command that the bot handles when it gets sent a message
    ## ..code-block:: nim
    ##
    ##    cmd.addChat("ping") do ():
    ##        discord.api.sendMessage(msg.channelID, "pong")
    ##
    result = addCommand(router, name, handler, ctChatCommand)

macro addSlash*(router: CommandHandler, name: static[string], handler: untyped): untyped =
    ## Add a new slash command to the handler
    ## A slash command is a command that the bot handles when the user uses slash commands
    ## 
    ## ..code-block:: nim
    ##    
    ##    cmd.addSlash("hello") do ():
    ##        ## I echo hello to the console
    ##        guildID: 1234567890 # Only add the command to a certain guild
    ##        echo "Hello world"
    result = addCommand(router, name, handler, ctSlashCommand)

proc getHandler(router: CommandHandler, name: string): ChatCommandProc =
    ## Returns the handler for a command with a certain name
    result = router.chatCommands[name].chatHandler

proc toCommand(command: ApplicationCommand): Command =
    result = Command(
        name: command.name,
        description: command.description
    )

proc toOptions(parameters: seq[ProcParameter]): seq[ApplicationCommandOption] =
    for parameter in parameters:
        result &= ApplicationCommandOption(
            kind: (case parameter.kind:
                        of "int": acotInt
                        of "string": acotStr
                        of "bool": acotBool
                        else:
                          raise newException(ValueError, parameter.kind & " is not supported")
                  ),
            name: parameter.name,
            description: "parameter",
            required: some parameter.optional
        )

proc toApplicationCommand(command: Command): ApplicationCommand =
    result = ApplicationCommand(
        name: command.name,
        description: command.description,
        options: command.parameters.toOptions()
    )

proc registerCommands*(handler: CommandHandler) {.async.} =
    ## Registers all the slash commands with discord
    # Get the bots application ID
    handler.applicationID = (await handler.discord.api.getCurrentApplication()).id
    var commands: seq[ApplicationCommand]
    for command in handler.slashCommands.values:
        commands &= command.toApplicationCommand()
    discard await handler.discord.api.bulkOverwriteApplicationCommands(handler.applicationID, commands, guildID = "479193574341214208")

proc handleMessage*(router: CommandHandler, prefix: string, msg: Message): Future[bool] {.async.} =
    ## Handles an incoming discord message and executes a command if necessary.
    ## This returns true if a command was found
    ## 
    ## ..code-block:: nim
    ## 
    ##    proc messageCreate (s: Shard, msg: Message) {.event(discord).} =
    ##        discard await router.handleMessage("$$", msg)
    ##     
    if not msg.content.startsWith(prefix): return
    let content = msg.content
    let startWhitespaceLength = skipWhitespace(msg.content, len(prefix))
    var name: string
    discard parseUntil(content, name, start = len(prefix) + startWhitespaceLength, until = Whitespace)
    if name == "help":
        discard await router.discord.api.sendMessage(msg.channelID, "", embed = some router.generateHelpMessage())
        result = true

    elif router.chatCommands.hasKey(name):
        let command = router.chatCommands[name]
        # TODO clean up this statement
        if command.guildID != "" and ((command.guildID != "" and msg.guildID.isSome()) and command.guildID != msg.guildID.get()):
            result = false
        else:
            await command.chatHandler(msg)
            result = true

proc handleInteraction*(router: CommandHandler, s: Shard, i: Interaction): Future[bool] {.async.}=
    let commandName = i.data.get().name
    # TODO add sub commands
    # TODO add guild specific slash commands
    if router.slashCommands.hasKey(commandName):
        let command = router.slashCommands[commandName]
        await command.slashHandler(i)
        result = true

proc handleMessage*(router: CommandHandler, prefixes: seq[string], msg: Message): Future[bool] {.async.} =
    ## Handles an incoming discord message and executes a command if necessary.
    ## This returns true if a command was found and executed. It will return once a prefix is correctly found
    ## 
    ## ..code-block:: nim
    ## 
    ##    proc messageCreate (s: Shard, msg: Message) {.event(discord).} =
    ##        discard await router.handleMessage(["$$", "&"], msg)
    ##
    for prefix in prefixes:
        if await router.handleMessage(prefix, msg): # Dont go through all the prefixes if one of them works
            return true

export parseutils
export strscans
export sequtils
export scanner
