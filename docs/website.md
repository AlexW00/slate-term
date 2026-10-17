# Website

The public site is [alexw00.github.io/slate-term](https://alexw00.github.io/slate-term/).

Edit [the standalone landing page](mockups/website-designs/f-apple-v2.html). Its styles, illustrations, and scripts are embedded in that file; open it directly in a browser to preview changes. The illustrations remain examples, and downloads are marked coming soon until a release is available.

The [Website workflow](../.github/workflows/pages.yml) deploys changes to that page from `main` through GitHub Pages. It copies the page to `index.html` and uploads only that file. The workflow can also be run manually from GitHub Actions.

Pages uses GitHub Actions as its publishing source and the default GitHub Pages address. No custom domain is configured.
