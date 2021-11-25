(import-macros {: require-fennel : dinfo} :hotpot.macros)
(local {:searcher macro-searcher} (require :hotpot.searcher.macro))
(local {: read-file!
        : write-file!
        : is-lua-path?
        : is-fnl-path?} (require :hotpot.fs))
(local debug-modname "hotpot.compiler")

;; we only want to inject the macro searcher once, but we also
;; only want to do it on demand since this front end to the compiler
;; is always loaded but not always used.
(var has-injected-macro-searcher false)
(fn compile-string [string options]
  ;; (string table) :: (true string) | (false string)
  ;; we only require fennel here because it can be heavy to pull in and *most*
  ;; of the time we will shortcut to the compiled lua.
  (local fennel (require-fennel))
  (when (not has-injected-macro-searcher)
    ;; we inject the macro searcher here, instead of in hotterpot.install because
    ;; it requires access to fennel directly.
    (table.insert fennel.macro-searchers 1 macro-searcher)
    (set has-injected-macro-searcher true))

  (local options (doto (or options {})
                       (tset :filename (or options.filename :hotpot-compile-string))))
  (fn compile []
    ;; drop the options table that is also returned
    (pick-values 1 (fennel.compile-string string options)))
  (xpcall compile fennel.traceback))

(fn compile-file [fnl-path lua-path options]
  ;; (string, string) :: (true, nil) | (false, errors)
  ;; TODO: make a nicer check/try/happy macro?
  (pcall (fn []
           (assert (is-fnl-path? fnl-path)
                   (string.format "compile-file fnl-path not fnl file: %q" fnl-path))
           (assert (is-lua-path? lua-path)
                   (string.format "compile-file lua-path not lua file: %q" lua-path))
           (local fnl-code (read-file! fnl-path))
           (dinfo :compile-file fnl-path lua-path)
           ; pass on any options to the compiler, but enforce the filename
           (local options (doto (or options {})
                                (tset :filename fnl-path)))
           (match (compile-string fnl-code options)
             (true lua-code) (do
                               ;; TODO normally this is fine if the dir exists
                               ;;      except if it ends in .  which can happen if
                               ;;      you're requiring a in-dir file
                               (dinfo :compile-file :OK)
                               (vim.fn.mkdir (string.match lua-path "(.+)/.-%.lua") :p)
                               (write-file! lua-path lua-code))
             (false errors) (do
                              (dinfo errors)
                              (error errors))))))

{: compile-string
 : compile-file}
