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

Each project is uploaded only to `s3://seanwade.com/misc/<name>/`. CloudFront
aliases are stored in the `seanwade-misc-routes` key-value store. Publishing
refuses to replace an alias owned by another project unless `--force` is used.
