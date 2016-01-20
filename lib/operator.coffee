# Libraries
# -------------------------
LineEndingRegExp = /(?:\n|\r\n)$/
_ = require 'underscore-plus'
{Point, Range, CompositeDisposable} = require 'atom'
BufferedProcess = null

{
  haveSomeSelection, getVimEofBufferPosition
  moveCursorLeft, moveCursorRight
  flashRanges, getNewTextRangeFromCheckpoint
} = require './utils'
swrap = require './selection-wrapper'
settings = require './settings'
Base = require './base'

# -------------------------
class OperatorError extends Base
  @extend(false)
  constructor: (@message) ->
    @name = 'Operator Error'

# General Operator
# -------------------------
class Operator extends Base
  @extend(false)
  recordable: true
  target: null
  flashTarget: true
  trackChange: false
  requireTarget: true

  setMarkForChange: ({start, end}) ->
    @vimState.mark.set('[', start)
    @vimState.mark.set(']', end)

  needFlash: ->
    @flashTarget and settings.get('flashOnOperate') and
      not (@constructor.name in settings.get('flashOnOperateBlacklist'))

  needTrackChange: ->
    @trackChange

  needStay: ->
    param = if @instanceof('TransformString')
      "stayOnTransformString"
    else
      "stayOn#{@constructor.name}"
    settings.get(param) or (@stayOnLinewise and @target.isLinewise?())

  constructor: ->
    super
    # Guard when Repeated.
    return if @instanceof("Repeat")

    # [important] intialized is not called when Repeated
    @initialize?()
    @setTarget @new(@target) if _.isString(@target)

  markSelectedBufferRange: ->
    @editor.markBufferRange @editor.getSelectedBufferRange(),
      invalidate: 'never'
      persistent: false

  observeSelectAction: ->
    if @needFlash()
      @onDidSelect =>
        @flash @editor.getSelectedBufferRanges()

    if @needTrackChange()
      marker = null
      @onDidSelect =>
        marker = @markSelectedBufferRange()

      @onDidOperationFinish =>
        @setMarkForChange(range) if (range = marker.getBufferRange())

  # @target - TextObject or Motion to operate on.
  setTarget: (@target) ->
    unless _.isFunction(@target.select)
      @vimState.emitter.emit('did-fail-to-set-target')
      targetName = @target.constructor.name
      operatorName = @constructor.name
      message = "Failed to set '#{targetName}' as target for Operator '#{operatorName}'"
      throw new OperatorError(message)
    @emitDidSetTarget(this)

  # Return true unless all selection is empty.
  # -------------------------
  selectTarget: ->
    @observeSelectAction()
    @emitWillSelect()
    @target.select()
    @emitDidSelect()
    haveSomeSelection(@editor)

  setTextToRegister: (text) ->
    if @target.isLinewise?() and not text.endsWith('\n')
      text += "\n"
    if text
      @vimState.register.set({text})

  flash: (ranges) ->
    if @flashTarget and settings.get('flashOnOperate')
      flashRanges ranges,
        editor: @editor
        class: 'vim-mode-plus-flash'
        timeout: settings.get('flashOnOperateDuration')

  preservePoints: ({asMarker}={}) ->
    points = _.pluck(@editor.getSelectedBufferRanges(), 'start')
    asMarker ?= false
    if asMarker
      options = {invalidate: 'never', persistent: false}
      markers = @editor.getCursorBufferPositions().map (point) =>
        @editor.markBufferPosition point, options
      ({cursor}, i) ->
        point = markers[i].getStartBufferPosition()
        cursor.setBufferPosition(point)
    else
      ({cursor}, i) ->
        point = points[i]
        cursor.setBufferPosition(point)

  eachSelection: (fn) ->
    setPoint = null
    if @needStay()
      @onWillSelect => setPoint = @preservePoints(@stayOption)
    else
      @onDidSelect => setPoint = @preservePoints()
    return unless @selectTarget()
    @editor.transact =>
      for selection, i in @editor.getSelections()
        fn(selection, setPoint.bind(this, selection, i))

# -------------------------
class Select extends Operator
  @extend(false)
  flashTarget: false
  recordable: false
  execute: ->
    @selectTarget()
    return if @isMode('operator-pending') or @isMode('visual', 'blockwise')
    if @target.isAllowSubmodeChange?()
      submode = swrap.detectVisualModeSubmode(@editor)
      if submode? and not @isMode('visual', submode)
        @activateMode('visual', submode)

class SelectLatestChange extends Select
  @extend()
  target: 'ALatestChange'

# -------------------------
class Delete extends Operator
  @extend()
  hover: icon: ':delete:', emoji: ':scissors:'
  trackChange: true
  flashTarget: false

  execute: ->
    @eachSelection (selection) =>
      {cursor} = selection
      @setTextToRegister(selection.getText()) if selection.isLastSelection()
      selection.deleteSelectedText()

      vimEof = getVimEofBufferPosition(@editor)
      if cursor.getBufferPosition().isGreaterThan(vimEof)
        cursor.setBufferPosition([vimEof.row, 0])

      cursor.skipLeadingWhitespace() if @target.isLinewise?()
    @activateMode('normal')

class DeleteRight extends Delete
  @extend()
  target: 'MoveRight'

class DeleteLeft extends Delete
  @extend()
  target: 'MoveLeft'

class DeleteToLastCharacterOfLine extends Delete
  @extend()
  target: 'MoveToLastCharacterOfLine'

# -------------------------
class TransformString extends Operator
  @extend(false)
  trackChange: true
  stayOnLinewise: true
  setPoint: true
  autoIndent: false

  execute: ->
    @eachSelection (s, setPoint) =>
      @mutate(s, setPoint)
    @activateMode('normal')

  mutate: (s, setPoint) ->
    text = @getNewText(s.getText())
    s.insertText(text, {@autoIndent})
    setPoint() if @setPoint

# String Transformer
# -------------------------
class ToggleCase extends TransformString
  @extend()
  hover: icon: ':toggle-case:', emoji: ':clap:'
  toggleCase: (char) ->
    if (charLower = char.toLowerCase()) is char
      char.toUpperCase()
    else
      charLower

  getNewText: (text) ->
    text.split('').map(@toggleCase).join('')

class ToggleCaseAndMoveRight extends ToggleCase
  @extend()
  hover: null
  setPoint: false
  target: 'MoveRight'

class UpperCase extends TransformString
  @extend()
  hover: icon: ':upper-case:', emoji: ':point_up:'
  getNewText: (text) ->
    text.toUpperCase()

class LowerCase extends TransformString
  @extend()
  hover: icon: ':lower-case:', emoji: ':point_down:'
  getNewText: (text) ->
    text.toLowerCase()

class CamelCase extends TransformString
  @extend()
  hover: icon: ':camel-case:', emoji: ':camel:'
  getNewText: (text) ->
    _.camelize text

class SnakeCase extends TransformString
  @extend()
  hover: icon: ':snake-case:', emoji: ':snake:'
  getNewText: (text) ->
    _.underscore text

class DashCase extends TransformString
  @extend()
  hover: icon: ':dash-case:', emoji: ':dash:'
  getNewText: (text) ->
    _.dasherize text

class TitleCase extends TransformString
  @extend()
  getNewText: (text) ->
    _.humanizeEventName(_.dasherize(text))

class EncodeUriComponent extends TransformString
  @extend()
  hover: icon: 'encodeURI', emoji: 'encodeURI'
  getNewText: (text) ->
    encodeURIComponent(text)

class DecodeUriComponent extends TransformString
  @extend()
  hover: icon: 'decodeURI', emoji: 'decodeURI'
  getNewText: (text) ->
    decodeURIComponent(text)

# -------------------------
class TranformStringByExternalCommand extends TransformString
  @extend(false)
  requireInput: true
  command: '' # e.g. command: 'sort'
  args: [] # e.g args: ['-rn']

  initialize: ->
    unless BufferedProcess?
      {BufferedProcess} = require 'atom'
    @results = []
    @exitCount = @runCount = 0

    @onDidSetTarget =>
      @restore = @preservePoints()
      @target.select()
      for selection, i in @editor.getSelections()
        @runExternalCommand(selection.getText())
        @restore(selection, i)

  runExternalCommand: (stdin) ->
    runCount = @runCount++
    stdout = (output) =>
      @results[runCount] = output

    exit = (code) =>
      @exitCount++
      if @exitCount is @runCount
        @input = @results
        @vimState.operationStack.process()

    bufferedprocess = new BufferedProcess({@command, @args, stdout, exit})
    bufferedprocess.process.stdin.write(stdin)
    bufferedprocess.process.stdin.end()

  getNewText: (text) ->
    # Return stdout of external command in order
    @input.shift() ? text

# -------------------------
class TransformStringBySelectList extends Operator
  @extend()
  requireInput: true
  requireTarget: true
  # Member of transformers can be either of
  # - Operation class name: e.g 'CamelCase'
  # - Operation class itself: e.g. CamelCase
  transformers: [
    'CamelCase'
    'DashCase'
    'SnakeCase'
    'LowerCase'
    'UpperCase'
    'ToggleCase'
    'EncodeUriComponent'
    'DecodeUriComponent'
    'JoinByInput'
    'JoinWithKeepingSpace'
    'Reverse'
    'SplitString'
    'Surround'
    'MapSurround'
    'TitleCase'
    'IncrementNumber'
    'DecrementNumber'
  ]

  getItems: ->
    @transformers.map (klass) ->
      className = if _.isString(klass) then klass else klass.name
      displayName = _.humanizeEventName(_.dasherize(className)).replace(/\bUri\b/, 'URI')
      {name: klass, displayName}

  initialize: ->
    @onDidSetTarget =>
      @focusSelectList({items: @getItems()})

    @vimState.onDidConfirmSelectList (transformer) =>
      @vimState.reset()
      @vimState.operationStack.run(transformer.name, {target: @target.constructor.name})

  execute: ->
    # NEVER be executed since operationStack is replaced with selected transformer

class TransformWordBySelectList extends TransformStringBySelectList
  @extend()
  target: "InnerWord"

class TransformSmartWordBySelectList extends TransformStringBySelectList
  @extend()
  target: "InnerSmartWord"

# -------------------------
class ReplaceWithRegister extends TransformString
  @extend()
  hover: icon: ':replace-with-register:', emoji: ':pencil:'
  getNewText: (text) ->
    @vimState.register.getText()

# -------------------------
class Indent extends TransformString
  @extend()
  hover: icon: ':indent:', emoji: ':point_right:'
  stayOnLinewise: false

  mutate: (s, setPoint) ->
    @indent(s)
    setPoint()
    unless @needStay()
      s.cursor.moveToFirstCharacterOfLine()

  indent: (s) ->
    s.indentSelectedRows()

class Outdent extends Indent
  @extend()
  hover: icon: ':outdent:', emoji: ':point_left:'
  indent: (s) ->
    s.outdentSelectedRows()

class AutoIndent extends Indent
  @extend()
  hover: icon: ':auto-indent:', emoji: ':open_hands:'
  indent: (s) ->
    s.autoIndentSelectedRows()

# -------------------------
class ToggleLineComments extends TransformString
  @extend()
  hover: icon: ':toggle-line-comments:', emoji: ':mute:'
  stayOption: {asMarker: true}
  mutate: (s, setPoint) ->
    s.toggleLineComments()
    setPoint()

# -------------------------
class Surround extends TransformString
  @extend()
  pairs: [
    ['[', ']']
    ['(', ')']
    ['{', '}']
    ['<', '>']
  ]
  input: null
  charsMax: 1
  hover: icon: ':surround:', emoji: ':two_women_holding_hands:'
  requireInput: true
  autoIndent: true

  initialize: ->
    return unless @requireInput
    @onDidConfirmInput (input) => @onConfirm(input)
    @onDidChangeInput (input) => @addHover(input)
    @onDidCancelInput => @vimState.operationStack.cancel()
    if @requireTarget
      @onDidSetTarget =>
        @vimState.input.focus({@charsMax})
    else
      @vimState.input.focus({@charsMax})

  onConfirm: (@input) ->
    @vimState.operationStack.process()

  getPair: (input) ->
    pair = _.detect @pairs, (pair) -> input in pair
    pair ?= [input, input]

  surround: (text, pair) ->
    [open, close] = pair
    if LineEndingRegExp.test(text)
      open += "\n"
      close += "\n"
    open + text + close

  getNewText: (text) ->
    @surround text, @getPair(@input)

class SurroundWord extends Surround
  @extend()
  target: 'InnerWord'

class SurroundSmartWord extends Surround
  @extend()
  target: 'InnerSmartWord'

class MapSurround extends Surround
  @extend()
  mapRegExp: /\w+/g
  execute: ->
    @eachSelection (s, setPoint) =>
      scanRange = s.getBufferRange()
      @editor.scanInBufferRange @mapRegExp, scanRange, ({matchText, replace}) =>
        replace(@getNewText(matchText))
      setPoint() if @setPoint
    @activateMode('normal')

class DeleteSurround extends Surround
  @extend()
  pairChars: ['[]', '()', '{}'].join('')
  requireTarget: false

  onConfirm: (@input) ->
    # FIXME: dont manage allowNextLine independently. Each Pair text-object can handle by themselvs.
    target = @new 'Pair',
      pair: @getPair(@input)
      inclusive: true
      allowNextLine: @input in @pairChars
    @setTarget(target)
    @vimState.operationStack.process()

  getNewText: (text) ->
    text[1...-1]

class DeleteSurroundAnyPair extends DeleteSurround
  @extend()
  requireInput: false
  target: 'AAnyPair'

class ChangeSurround extends DeleteSurround
  @extend()
  charsMax: 2
  char: null

  onConfirm: (input) ->
    return unless input
    [from, @char] = input.split('')
    super(from)

  getNewText: (text) ->
    @surround super(text), @getPair(@char)

class ChangeSurroundAnyPair extends ChangeSurround
  @extend()
  charsMax: 1
  target: "AAnyPair"

  initialize: ->
    @onDidSetTarget =>
      @restore = @preservePoints()
      @target.select()
      unless haveSomeSelection(@editor)
        @vimState.reset()
        @abort()
      @addHover(@editor.getSelectedText()[0])
    super

  onConfirm: (@char) ->
    # Clear pre-selected selection to start @eachSelection from non-selection.
    @restore(s, i) for s, i in @editor.getSelections()
    @input = @char
    @vimState.operationStack.process()

# -------------------------
# Performance effective than nantive editor:move-line-up/down
class MoveLineUp extends TransformString
  @extend()
  direction: 'up'
  execute: ->
    @eachSelection (s, setPoint) =>
      @mutate(s, setPoint)

  isMovable: (s) ->
    s.getBufferRange().start.row isnt 0

  getRangeTranslationSpec: ->
    [[-1, 0], [0, 0]]

  mutate: (s, setPoint) ->
    return unless @isMovable(s)
    reversed = s.isReversed()
    translation = @getRangeTranslationSpec()
    swrap(s).translate(translation, {preserveFolds: true})
    rows = swrap(s).lineTextForBufferRows()
    @rotateRows(rows)
    range = s.insertText(rows.join("\n") + "\n")
    range = range.translate(translation.reverse()...)
    swrap(s).setBufferRange(range, {preserveFolds: true, reversed})
    @editor.scrollToCursorPosition({center: true})

  isLastRow: (row) ->
    row is @editor.getBuffer().getLastRow()

  rotateRows: (rows) ->
    rows.push(rows.shift())

class MoveLineDown extends MoveLineUp
  @extend()
  direction: 'down'
  isMovable: (s) ->
    not @isLastRow(s.getBufferRange().end.row)

  rotateRows: (rows) ->
    rows.unshift(rows.pop())

  getRangeTranslationSpec: ->
    [[0, 0], [1, 0]]

# -------------------------
class Yank extends Operator
  @extend()
  hover: icon: ':yank:', emoji: ':clipboard:'
  trackChange: true
  stayOnLinewise: true

  execute: ->
    @eachSelection (s, setPoint) =>
      @setTextToRegister s.getText() if s.isLastSelection()
      setPoint()
    @activateMode('normal')

class YankLine extends Yank
  @extend()
  target: 'MoveToRelativeLine'

# -------------------------
# FIXME
# Currently native editor.joinLines() is better for cursor position setting
# So I use native methods for a meanwhile.
class Join extends Operator
  @extend()
  requireTarget: false
  execute: ->
    @editor.transact =>
      _.times @getCount(), =>
        @editor.joinLines()
    @activateMode('normal')

class JoinWithKeepingSpace extends TransformString
  @extend()
  input: ''
  requireTarget: false
  trim: false
  initialize: ->
    @setTarget @new("MoveToRelativeLineWithMinimum", {min: 1})

  mutate: (s) ->
    [startRow, endRow] = s.getBufferRowRange()
    swrap(s).expandOverLine()
    rows = for row in [startRow..endRow]
      text = @editor.lineTextForBufferRow(row)
      if @trim and row isnt startRow
        text.trimLeft()
      else
        text
    s.insertText @join(rows) + "\n"

  join: (rows) ->
    rows.join(@input)

class JoinByInput extends JoinWithKeepingSpace
  @extend()
  hover: icon: ':join:', emoji: ':couple:'
  requireInput: true
  input: null
  trim: true
  initialize: ->
    super
    @focusInput(charsMax: 10)

  join: (rows) ->
    rows.join(" #{@input} ")

class JoinByInputWithKeepingSpace extends JoinByInput
  @extend()
  trim: false
  join: (rows) ->
    rows.join(@input)

# -------------------------
# String suffix in name is to avoid confusion with 'split' window.
class SplitString extends TransformString
  @extend()
  hover: icon: ':split-string:', emoji: ':hocho:'
  requireInput: true
  input: null

  initialize: ->
    if not @isMode('visual')
      @setTarget @new("MoveToRelativeLine", {min: 1})
    @focusInput(charsMax: 10)

  getNewText: (text) ->
    @input = "\\n" if @input is ''
    regex = ///#{_.escapeRegExp(@input)}///g
    text.split(regex).join("\n")

class Reverse extends TransformString
  @extend()
  mutate: (s, setPoint) ->
    swrap(s).expandOverLine()
    textForRows = swrap(s).lineTextForBufferRows()
    newText = textForRows.reverse().join("\n") + "\n"
    s.insertText(newText)
    setPoint()

# -------------------------
class Repeat extends Operator
  @extend()
  requireTarget: false
  recordable: false
  execute: ->
    @editor.transact =>
      _.times @getCount(), =>
        if op = @vimState.operationStack.getRecorded()
          op.setRepeated()
          op.execute()

# -------------------------
class Mark extends Operator
  @extend()
  hover: icon: ':mark:', emoji: ':round_pushpin:'
  requireInput: true
  requireTarget: false
  initialize: ->
    @focusInput()

  execute: ->
    @vimState.mark.set(@input, @editor.getCursorBufferPosition())
    @activateMode('normal')

# -------------------------
# [FIXME?]: inconsistent behavior from normal operator
# Since its support visual-mode but not use setTarget() convension.
# Maybe separating complete/in-complete version like IncreaseNow and Increase?
class Increase extends Operator
  @extend()
  requireTarget: false
  step: 1

  execute: ->
    pattern = ///#{settings.get('numberRegex')}///g

    newRanges = []
    @editor.transact =>
      for c in @editor.getCursors()
        scanRange = if @isMode('visual')
          c.selection.getBufferRange()
        else
          c.getCurrentLineBufferRange()
        ranges = @increaseNumber(c, scanRange, pattern)
        if not @isMode('visual') and ranges.length
          c.setBufferPosition ranges[0].end.translate([0, -1])
        newRanges.push ranges

    if (newRanges = _.flatten(newRanges)).length
      @flash newRanges
    else
      atom.beep()

  increaseNumber: (cursor, scanRange, pattern) ->
    newRanges = []
    @editor.scanInBufferRange pattern, scanRange, ({matchText, range, stop, replace}) =>
      newText = String(parseInt(matchText, 10) + @step * @getCount())
      if @isMode('visual')
        newRanges.push replace(newText)
      else
        return unless range.end.isGreaterThan cursor.getBufferPosition()
        newRanges.push replace(newText)
        stop()
    newRanges

class Decrease extends Increase
  @extend()
  step: -1

# -------------------------
class IncrementNumber extends Operator
  @extend()
  step: 1
  baseNumber: null

  execute: ->
    pattern = ///#{settings.get('numberRegex')}///g
    newRanges = null
    @selectTarget()
    @editor.transact =>
      newRanges = for s in @editor.getSelectionsOrderedByBufferPosition()
        @replaceNumber(s.getBufferRange(), pattern)
    if (newRanges = _.flatten(newRanges)).length
      @flash newRanges
    else
      atom.beep()
    for s in @editor.getSelections()
      s.cursor.setBufferPosition(s.getBufferRange().start)
    @activateMode('normal')

  replaceNumber: (scanRange, pattern) ->
    newRanges = []
    @editor.scanInBufferRange pattern, scanRange, ({matchText, replace}) =>
      newRanges.push replace(@getNewText(matchText))
    newRanges

  getNewText: (text) ->
    @baseNumber = if @baseNumber?
      @baseNumber + @step * @getCount()
    else
      parseInt(text, 10)
    String(@baseNumber)

class DecrementNumber extends IncrementNumber
  @extend()
  step: -1

# Put
# -------------------------
class PutBefore extends Operator
  @extend()
  requireTarget: false
  location: 'before'

  execute: ->
    {text, type} = @vimState.register.get()
    return unless text
    text = _.multiplyString(text, @getCount())
    isLinewise = type is 'linewise' or @isMode('visual', 'linewise')

    @editor.transact =>
      for s in @editor.getSelections()
        {cursor} = s
        if isLinewise
          newRange = @pasteLinewise(s, text)
          cursor.setBufferPosition(newRange.start)
          cursor.moveToFirstCharacterOfLine()
        else
          newRange = @pasteCharacterwise(s, text)
          cursor.setBufferPosition(newRange.end.translate([0, -1]))
        @setMarkForChange(newRange)
        @flash newRange
    @activateMode('normal')

  # Return newRange
  pasteLinewise: (selection, text) ->
    {cursor} = selection
    if selection.isEmpty()
      text = text.replace(LineEndingRegExp, '')
      if @location is 'before'
        @insertTextAbove(selection, text)
      else
        @insertTextBelow(selection, text)
    else
      if @isMode('visual', 'linewise')
        text += '\n' unless text.endsWith('\n')
      else
        selection.insertText("\n")
      selection.insertText(text)

  pasteCharacterwise: (selection, text) ->
    if @location is 'after' and selection.isEmpty()
      selection.cursor.moveRight()
    selection.insertText(text)

  insertTextAbove: (selection, text) ->
    selection.cursor.moveToBeginningOfLine()
    selection.insertText("\n")
    selection.cursor.moveUp()
    selection.insertText(text)

  insertTextBelow: (selection, text) ->
    selection.cursor.moveToEndOfLine()
    selection.insertText("\n")
    selection.insertText(text)

class PutAfter extends PutBefore
  @extend()
  location: 'after'

# Replace
# -------------------------
class Replace extends Operator
  @extend()
  input: null
  hover: icon: ':replace:', emoji: ':tractor:'
  flashTarget: false
  trackChange: true
  requireInput: true
  requireTarget: false

  initialize: ->
    @setTarget @new('MoveRight') if @isMode('normal')
    @focusInput()

  execute: ->
    @input = "\n" if @input is ''
    @eachSelection (s, setPoint) =>
      text = s.getText().replace(/./g, @input)
      unless (@target.instanceof('MoveRight') and (text.length < @getCount()))
        s.insertText(text, autoIndentNewline: true)
      setPoint() unless @input is "\n"

    # FIXME this is very imperative, handling in very lower level.
    # find better place for operator in blockwise move works appropriately.
    if @isMode('visual', 'blockwise')
      top = @editor.getSelectionsOrderedByBufferPosition()[0]
      s.destroy() for s in @editor.getSelections() when (s isnt top)

    @activateMode('normal')

# Insert entering operation
# -------------------------
class ActivateInsertMode extends Operator
  @extend()
  requireTarget: false
  flashTarget: false
  checkpoint: null
  submode: null
  supportInsertionCount: true

  withAddedBufferRangeFromCheckpoint: (purpose, fn) ->
    range = getNewTextRangeFromCheckpoint(@editor, @getCheckpoint(purpose))
    fn(range) if range?

  observeWillDeactivateMode: ->
    disposable = @vimState.modeManager.preemptWillDeactivateMode ({mode}) =>
      return unless mode is 'insert'
      disposable.dispose()

      @vimState.mark.set('^', @editor.getCursorBufferPosition())
      text = ''
      if (range = getNewTextRangeFromCheckpoint(@editor, @getCheckpoint('insert')))?
        @setMarkForChange(range) # Marker can track following extra insertion incase count specified
        text = @editor.getTextInBufferRange(range)
      @saveInsertedText(text)
      @vimState.register.set('.', {text})

      _.times @getInsertionCount(), =>
        text = @textByOperator + @getInsertedText()
        for selection in @editor.getSelections()
          selection.insertText(text, autoIndent: true)

      # grouping changes for undo checkpoint need to come last
      @editor.groupChangesSinceCheckpoint(@getCheckpoint('undo'))

  initialize: ->
    @checkpoint = {}
    @setCheckpoint('undo') unless @isRepeated()
    @observeWillDeactivateMode()

  # we have to manage two separate checkpoint for different purpose(timing is different)
  # - one for undo(handled by modeManager)
  # - one for preserve last inserted text
  setCheckpoint: (purpose) ->
    @checkpoint[purpose] = @editor.createCheckpoint()

  getCheckpoint: (purpose) ->
    @checkpoint[purpose]

  saveInsertedText: (@insertedText) -> @insertedText

  getInsertedText: ->
    @insertedText ? ''

  # called when repeated
  repeatInsert: (selection, text) ->
    selection.insertText(text, autoIndent: true)

  getInsertionCount: ->
    @insertionCount ?= if @supportInsertionCount then (@getCount() - 1) else 0
    @insertionCount

  execute: ->
    if @isRepeated()
      return unless text = @getInsertedText()
      unless @instanceof('Change')
        @flashTarget = @trackChange = true
        @observeSelectAction()
        @emitDidSelect()
      @editor.transact =>
        for s in @editor.getSelections()
          @repeatInsert(s, text)
          moveCursorLeft(s.cursor)
    else
      if @getInsertionCount() > 0
        range = getNewTextRangeFromCheckpoint(@editor, @getCheckpoint('undo'))
        @textByOperator = if range? then @editor.getTextInBufferRange(range) else ''
      @setCheckpoint('insert')
      @vimState.activate('insert', @submode)

class InsertAtLastInsert extends ActivateInsertMode
  @extend()
  execute: ->
    if (point = @vimState.mark.get('^'))
      @editor.setCursorBufferPosition(point)
      @editor.scrollToCursorPosition({center: true})
    super

class ActivateReplaceMode extends ActivateInsertMode
  @extend()
  submode: 'replace'

  repeatInsert: (selection, text) ->
    for char in text when char isnt "\n"
      break if selection.cursor.isAtEndOfLine()
      selection.selectRight()
    selection.insertText(text, autoIndent: false)

class InsertAfter extends ActivateInsertMode
  @extend()
  execute: ->
    moveCursorRight(c) for c in @editor.getCursors()
    super

class InsertAfterEndOfLine extends ActivateInsertMode
  @extend()
  execute: ->
    @editor.moveToEndOfLine()
    super

class InsertAtBeginningOfLine extends ActivateInsertMode
  @extend()
  execute: ->
    @editor.moveToBeginningOfLine()
    @editor.moveToFirstCharacterOfLine()
    super

class InsertByMotion extends ActivateInsertMode
  @extend()
  requireTarget: true
  execute: ->
    if @target.instanceof('Motion')
      @target.execute()
    if @instanceof('InsertAfterByMotion')
      moveCursorRight(c) for c in @editor.getCursors()
    super

class InsertAfterByMotion extends InsertByMotion
  @extend()

class InsertAtPreviousFoldStart extends InsertByMotion
  @extend()
  target: 'MoveToPreviousFoldStart'

class InsertAtNextFoldStart extends InsertAtPreviousFoldStart
  @extend()
  target: 'MoveToNextFoldStart'

class InsertAboveWithNewline extends ActivateInsertMode
  @extend()
  execute: ->
    @insertNewline()
    super

  insertNewline: ->
    @editor.insertNewlineAbove()

  repeatInsert: (selection, text) ->
    selection.insertText(text.trimLeft(), autoIndent: true)

class InsertBelowWithNewline extends InsertAboveWithNewline
  @extend()
  insertNewline: ->
    @editor.insertNewlineBelow()
# -------------------------
class Change extends ActivateInsertMode
  @extend()
  requireTarget: true
  trackChange: true
  supportInsertionCount: false

  execute: ->
    unless @selectTarget()
      @activateMode('normal')
      return

    @setTextToRegister @editor.getSelectedText()
    text = ''
    text += "\n" if @target.isLinewise?()
    @editor.transact =>
      for selection in @editor.getSelections()
        range = selection.insertText(text, autoIndent: true)
        selection.cursor.moveLeft() unless range.isEmpty()
    super

class Substitute extends Change
  @extend()
  target: 'MoveRight'

class SubstituteLine extends Change
  @extend()
  target: 'MoveToRelativeLine'

class ChangeToLastCharacterOfLine extends Change
  @extend()
  target: 'MoveToLastCharacterOfLine'
