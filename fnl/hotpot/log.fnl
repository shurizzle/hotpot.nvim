;; cant require anything in this file

(local path-sep (string.match package.config "(.-)\n"))
(local path (.. (vim.fn.stdpath :cache) path-sep :hotpot.log))
(var out-file nil)

(fn open []
  (match (io.open path :w) ;; trunc log so it doesn't bloat I guess
    fd (set out-file fd)
    (nil error) (print "hotpot error: could not open log file for writing")))

(fn log-msg [line]
  (if (not out-file) (open))
  (out-file:write (.. line "\n"))
  (out-file:flush))

{: log-msg}
