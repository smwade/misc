# sw misc-site publisher

`sw` publishes self-contained static projects to `seanwade.com`. Project files
are stored under the protected internal `misc/` namespace. Optional root aliases
can expose a clean URL such as `https://seanwade.com/demo.html` without moving
the object out of that namespace.

## Typical use

From a folder containing a standalone HTML file:

```sh
sw publish guide.html
```

The first publish creates `.sw.json`. Later updates are simply:

```sh
sw publish
```

For a built site:

```sh
sw init dist --name particle-lab --build "bun run build"
sw preview
sw publish
```

Useful commands:

```sh
sw status
sw list
sw open
sw unpublish
```

For a GitHub repository owned by `smwade`, opt into automatic publishing from
its `main` branch:

```sh
sw enable-github
git add .sw.json .github/workflows/publish-misc.yml
git commit -m "Publish site automatically"
git push
```

This registers only that repository's `main` branch in the AWS OIDC trust
policy. GitHub receives short-lived credentials and no AWS keys are stored as
repository secrets.

Each project is uploaded only to `s3://seanwade.com/misc/<name>/`. CloudFront
aliases are stored in the `seanwade-misc-routes` key-value store. Publishing
refuses to replace an alias owned by another project unless `--force` is used.
