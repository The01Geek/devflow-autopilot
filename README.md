# DevFlow — published site (GitHub Pages)

**This branch (`gh-pages`) is the Pages publishing source.** Its root is the site
root, e.g. `DevFlow-Loop.html` is served at
`https://the01geek.github.io/devflow-autopilot/DevFlow-Loop.html`.

The content used to live at `docs/site/` on `main` and was published by a
`.github/workflows/pages.yml` Actions workflow. It was moved here so the plugin
payload stops carrying it: a marketplace `/plugin install` shallow-clones the
repository and copies the whole subtree unfiltered, so every tracked byte at
`main`'s HEAD ships to every installing user. These four files were 4.26 MB of a
10.64 MB packed clone.

Pages now publishes straight from this branch (build type "deploy from a branch",
source `gh-pages` / `/`), so a push here deploys — no workflow involved.

## Adding a page

Drop a self-contained `.html` one-pager at the root of this branch and push. No
spaces in filenames — they become `%20` in URLs.

`.nojekyll` is present and must stay: it disables Jekyll processing so files and
directories beginning with `_` or `.` are served verbatim.
