# System dashboard

This Flask app pairs a Vue.js file explorer with a live, read-only `btop`
terminal. The system monitor appears above the file explorer on all screen
sizes. The explorer lists folders and file metadata only; it does not open or
modify files.

## Setup and run

Run `./setup.sh`, then start the server:

```sh
.venv/bin/python app.py
```

Open <http://127.0.0.1:5000>. The page loads Vue.js and xterm.js from jsDelivr,
so the browser needs access to that CDN.

The explorer defaults to `/`, as configured for this installation. Set
`FILE_EXPLORER_ROOT` to a narrower directory before starting the server to
restrict browsing. Directory listings reflect the server process's permissions.
The server listens on localhost by default; only expose it on trusted networks
because it displays host metrics and filesystem names.