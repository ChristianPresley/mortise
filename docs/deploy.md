# Deploying

`mortise build` writes the finished site to `_site/`. It is plain files:
copy the folder to any web server or static host.

## GitHub Pages

Sites made with `mortise new` include `.github/workflows/pages.yml`. On
every push to `main` it:

1. downloads the Mortise release the site was created with, and checks it
   against the release's `SHA256SUMS`;
2. runs `mortise build`;
3. publishes `_site/` with GitHub's own Pages actions.

To turn it on, push the site to a GitHub repository and set **Settings >
Pages > Source** to **GitHub Actions**. Then:

- For a user or organization site (`https://USER.github.io/`), nothing
  else is needed.
- For a project site (`https://USER.github.io/REPO/`), set the base URL
  in `_config.yml`, so page links and `site.baseurl` include it:

  ```yaml
  baseurl: /REPO
  ```

  Mortise adds `baseurl` to page URLs and templates, but not to links
  written in Markdown, so use relative links there (`docs/`,
  `../configuration/`).

To build with a newer Mortise, change `MORTISE_VERSION` at the top of the
workflow.

To add the workflow to an existing site, copy `.github/workflows/pages.yml`
from a new site (`mortise new tmp`) and adjust `MORTISE_VERSION`.

## Other hosts

Any host that serves a folder works. Build with `mortise build` and
upload `_site/`, or have the host run the build:

- **Netlify, Cloudflare Pages, Vercel:** download a Mortise release in the
  build command, then run `mortise build`; the publish directory is
  `_site`.
- **Your own server:** `rsync -a --delete _site/ server:/var/www/site/`.

## Releasing Mortise

For maintainers: bump `version` in `src/root.zig`, merge, and push a tag
named after it (`v0.2.0`). The release workflow
(`.github/workflows/release.yml`) checks that the tag matches the
version, runs the tests, cross-compiles Mortise for x86_64 and aarch64
Linux (static, musl), macOS and Windows, and publishes the archives and a
`SHA256SUMS` file as a GitHub release.
