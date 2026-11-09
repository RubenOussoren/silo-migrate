# Theme credit

The web UI's look comes from **Varnish** by Keegan George,
<https://github.com/keegangeorge/term-llm-varnish>, under the MIT License. A copy is in
`../varnish/`, unmodified, with its `LICENSE`. Its fonts, Geist and Geist Mono (© Vercel), are under
the SIL Open Font License 1.1: see `../varnish/fonts/OFL.txt`.

This `silo-theme` extension holds only our changes, and is enabled after Varnish. To take a new
version, run `script/update-varnish COMMIT`; `varnish-upstream.json` records what's installed.
Never edit `../varnish/` by hand.
