# [DANGER]
# What I'm doing in this test-spec is SUPER hacky, and I don't like this.
#
# - What I'm doing and why
#  - Invalidate require.cache to "observe required file on startup".
#  - Then restore require.cache to original state.
#
# - Just invalidating is not enough unless restoreing other spec file fail.
#
# - What happens just invalidate require.cache and NOT restored to original require.cache?
#  - For module such like `globlal-state.coffee` it instantiated at required time.
#  - Invalidating require.cache for `global-state.coffee` means, it's reloaded again.
#  - This 2nd reload return DIFFERENT globalState instance.
#  - So globalState is now no longer globally referencing same same object, it's broken.
#  - This situation is caused by explicit cache invalidation and not happen in real usage.
#
# - I know this spec is still super hacky and I want to find safer way.
#  - But I need this spec to detect unwanted file is required at startup( vmp get slower startup ).
describe "dirty work for fast package activation", ->
  withCleanActivation = null
  ensureRequiredFiles = null

  beforeEach ->
    runs ->
      packPath = atom.packages.loadPackage('vim-mode-plus').path

      getRequiredLibOrNodeModulePaths = ->
        Object.keys(require.cache).filter (p) ->
          p.startsWith(packPath + 'lib') or p.startsWith(packPath + 'node_modules')

      # Return function to restore original require.cache of interest
      cleanRequireCache = ->
        savedCache = {}
        oldPaths = getRequiredLibOrNodeModulePaths()
        oldPaths.forEach (p) ->
          savedCache[p] = require.cache[p]
          delete require.cache[p]

        return ->
          oldPaths.forEach (p) ->
            require.cache[p] = savedCache[p]
          getRequiredLibOrNodeModulePaths().forEach (p) ->
            if p not in oldPaths
              delete require.cache[p]

      withCleanActivation = (fn) ->
        restoreRequireCache = null
        runs ->
          restoreRequireCache = cleanRequireCache()
        waitsForPromise ->
          atom.packages.activatePackage('vim-mode-plus').then(fn)
        runs ->
          restoreRequireCache()

      ensureRequiredFiles = (files) ->
        should = files.map((file) -> packPath + file)

        # console.log "# should", should.join("\n")
        # console.log "# actual", getRequiredLibOrNodeModulePaths().join("\n")

        expect(getRequiredLibOrNodeModulePaths()).toEqual(should)

  # * To reduce IO and compile-evaluation of js file on startup
  describe "requrie as minimum num of file as possible on startup", ->
    shouldRequireFilesInOrdered = [
      "lib/main.js"
      "lib/base.js"
      "lib/settings.js"
      "lib/vim-state.js"
      "lib/command-table.json"
    ]
    if atom.inDevMode()
      shouldRequireFilesInOrdered.push('lib/developer.js')

    it "THIS IS WORKAROUND FOR Travis-CI's", ->
      # HACK:
      # After very first call of atom.packages.activatePackage('vim-mode-plus')
      # require.cache is NOT populated yet on Travis-CI.
      # It doesn't include lib/main.coffee( this is odd state! ).
      # This only happens in very first activation.
      # So puting here useless test just activate package can be workaround.
      withCleanActivation ->
        null

    it "require minimum set of files", ->
      withCleanActivation ->
        ensureRequiredFiles(shouldRequireFilesInOrdered)

    it "[one editor opened] require minimum set of files", ->
      withCleanActivation ->
        waitsForPromise ->
          atom.workspace.open()
        runs ->
          files = shouldRequireFilesInOrdered.concat('lib/status-bar-manager.js')
          ensureRequiredFiles(files)

    it "[after motion executed] require minimum set of files", ->
      withCleanActivation ->
        waitsForPromise ->
          atom.workspace.open().then (e) ->
            atom.commands.dispatch(e.element, 'vim-mode-plus:move-right')
        runs ->
          extraShouldRequireFilesInOrdered = [
            "lib/status-bar-manager.js"
            "lib/operation-stack.js"
            "lib/file-table.json"
            "lib/motion.js"
            "node_modules/underscore-plus/lib/underscore-plus.js"
            "node_modules/underscore/underscore.js"
            "lib/utils.js"
            "lib/cursor-style-manager.js"
          ]
          files = shouldRequireFilesInOrdered.concat(extraShouldRequireFilesInOrdered)
          ensureRequiredFiles(files)

  describe "command-table", ->
    # * Loading atom commands from pre-generated command-table.
    # * Why?
    #  vmp adds about 300 cmds, which is huge, dynamically calculating and register cmds
    #  took very long time.
    #  So calcluate non-dynamic par then save to command-table.coffe and load in on startup.
    #  When command are executed, necessary command class file is lazy-required.
    describe "initial classRegistry", ->
      it "is empty", ->
        withCleanActivation (pack) ->
          Base = pack.mainModule.provideVimModePlus().Base
          expect(Object.keys(Base.classTable)).toHaveLength(0)

    describe "fully populated classRegistry", ->
      it "buildCommandTable populate all class table eagerly", ->
        withCleanActivation (pack) ->
          Base = pack.mainModule.provideVimModePlus().Base
          expect(Object.keys(Base.classTable)).toHaveLength(0)
          Base.buildCommandTableAndFileTable()
          expect(Object.keys(Base.classTable).length).toBeGreaterThan(0)

    describe "make sure command-table and file-table is NOT out-of-date", ->
      it "buildCommandTable return table which is equals to initially loaded command table", ->
        withCleanActivation (pack) ->
          Base = pack.mainModule.provideVimModePlus().Base
          {commandTable: oldCommandTable, fileTable: oldFileTable} = Base
          {commandTable: newCommandTable, fileTable: newFileTable} = Base.buildCommandTableAndFileTable()

          expect(oldCommandTable).not.toBe(newCommandTable)
          expect(oldCommandTable).toEqual(newCommandTable)

          expect(oldFileTable).not.toBe(newFileTable)
          expect(oldFileTable).toEqual(newFileTable)
