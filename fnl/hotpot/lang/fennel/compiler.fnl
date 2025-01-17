(import-macros {: expect} :hotpot.macros)

;; we only want to inject the macro searcher once, but we also
;; only want to do it on demand since this front end to the compiler
;; is always loaded but not always used.
(var injected-macro-searcher? false)

(fn make-macro-loader [modname fnl-path]
  (let [fennel (require :hotpot.fennel)
        {: read-file!} (require :hotpot.fs)
        {: config} (require :hotpot.runtime)
        user-preprocessor (. config :compiler :preprocessor)
        preprocessor (fn [src]
                       (user-preprocessor src {:macro? true
                                               :path fnl-path
                                               :modname modname}))
        code (case (-> (read-file! fnl-path) (preprocessor))
               (nil err) (error err)
               src src)]
    (fn [modname]
      ;; require the depencency map module *inside* the load function
      ;; to avoid circular dependencies.
      ;; By putting it here we can be sure that the dep map module is already
      ;; in memory before hotpot took over macro module searching.
      (let [dep-map (require :hotpot.dependency-map)
            {: config} (require :hotpot.runtime)
            options (doto (. config :compiler :macros)
                          (tset :filename fnl-path)
                          (tset :module-name modname))]
        ;; later, when a module needs a macro, we will know what file the
        ;; macro came from and can then track the macro file for changes
        ;; when refreshing the cache.
        (dep-map.set-macro-modname-path modname fnl-path)
        ;; eval macro as per fennel's implementation.
        (fennel.eval code options modname)))))

(fn macro-searcher [modname]
  (let [{: search} (require :hotpot.searcher)
        spec  {:prefix :fnl
               :extension :fnl
               :modnames [(.. modname :.init-macros)
                          (.. modname :.init)
                          modname]}]
    (case-try
      (search spec) [path]
      (make-macro-loader modname path))))

(fn compile-string [string options]
  "Compile given string of fennel into lua, returns `true lua` or `false error`"
  ;; (string table) :: (true string) | (false string)
  ;; we only require fennel here because it can be heavy to pull in and *most*
  ;; of the time we will shortcut to the compiled lua.
  (local fennel (require :hotpot.fennel))
  (local {: traceback} (require :hotpot.runtime))
  (when (not injected-macro-searcher?)
    ;; We need the fennel module in memory to insert our searcher,
    ;; so we wait until we actually get a compile request to do it for
    ;; performance reasons.
    (table.insert fennel.macro-searchers 1 macro-searcher)
    (set injected-macro-searcher? true))

  (local options (doto (or options {})
                       (tset :filename (or options.filename :hotpot-compile-string))))
  (fn compile []
    ;; drop the options table that is also returned
    (pick-values 1 (fennel.compile-string string options)))
  (xpcall compile traceback))

(fn compile-file [fnl-path lua-path options ?preprocessor]
  "Compile fennel code from `fnl-path` and save to `lua-path`"
  ;; (string, string) :: (true, nil) | (false, errors)
  (fn check-existing [path]
    (let [uv vim.loop
          {: type} (or (uv.fs_stat path) {})]
      (expect (or (= :file type) (= nil type))
              "Refusing to write to %q, it exists as a %s" path type)))
  (fn do-compile []
    (let [{: read-file!
           : write-file!
           : path-separator
           : is-lua-path?
           : is-fnl-path?
           : make-path
           : dirname} (require :hotpot.fs)
          preprocessor (or ?preprocessor (fn [src] src))
          _ (expect (is-fnl-path? fnl-path) "compile-file fnl-path not fnl file: %q" fnl-path)
          _ (expect (is-lua-path? lua-path) "compile-file lua-path not lua file: %q" lua-path)
          fnl-code (case (-> (read-file! fnl-path) (preprocessor))
                     (nil err) (error err)
                     src src)
          ;; pass on any options to the compiler, but enforce the filename
          ;; we use the whole fennel file path as that can be a bit clearer.
          options (doto (or options {})
                        (tset :filename fnl-path))]
      (case (compile-string fnl-code options)
        (true lua-code) (let []
                          (check-existing lua-path)
                          (make-path (dirname lua-path))
                          (write-file! lua-path lua-code))
        (false errors) (error errors))))
  (pcall do-compile))

(λ compile-record [record]
  "Compile fnl-path to lua-path, returns true or false compilation-errors"
  (let [{: deps-for-fnl-path} (require :hotpot.dependency-map)
        {: config} (require :hotpot.runtime)
        {: lua-path : src-path : modname} record
        {:new new-macro-dep-tracking-plugin} (require :hotpot.lang.fennel.dependency-tracker)
        options (. config :compiler :modules)
        user-preprocessor (. config :compiler :preprocessor)
        preprocessor (fn [src]
                       (user-preprocessor src {:macro? false
                                               :path src-path
                                               :modname modname}))
        plugin (new-macro-dep-tracking-plugin src-path modname)]
    ;; inject our plugin, must only exist for this compile-file call because it
    ;; depends on the specific fnl-path closure value, so we will table.remove
    ;; it after calling compile. It *is* possible to have multiple plugins
    ;; attached for nested requires but this is ok.
    ;; TODO: this should *probably* be a copy, but would have to be, half
    ;; shallow, half not (as the options may be heavy for things using _G etc).
    ;; It could be a shallow-copy + plugins copy since we directly modify that?
    (tset options :plugins (or options.plugins []))
    (tset options :module-name modname)
    (table.insert options.plugins 1 plugin)
    (local (ok? extra) (case-try
                         (compile-file src-path lua-path options preprocessor) true
                         (or (deps-for-fnl-path src-path) []) deps
                         (values true deps)))
    (table.remove options.plugins 1)
    (values ok? extra)))

{: compile-string
 : compile-file
 : compile-record}
