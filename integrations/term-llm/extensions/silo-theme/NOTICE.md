# Theme credit

The web UI's look comes from **Varnish** by Keegan George,
<https://github.com/keegangeorge/term-llm-varnish>, under the MIT License. A copy is in
`../varnish/`, with its `LICENSE`, unmodified except two compatibility patches: term-llm 0.9.99's
Runtime popover (in `main.js` and `style.css`; submitted upstream as keegangeorge/term-llm-varnish#20)
and the node's id behind the Hub's `/hub/node/<id>/` paths (in `util.js`). Both are recorded in
`varnish-upstream.json`. Its fonts, Geist and Geist Mono (© Vercel), are under
the SIL Open Font License 1.1: see `../varnish/fonts/OFL.txt`.

This `silo-theme` extension holds only our changes, and is enabled after Varnish. To take a new
version, run `script/update-varnish COMMIT`; `varnish-upstream.json` records what's installed.
Never edit `../varnish/` by hand: `script/update-varnish` applies the patches.
