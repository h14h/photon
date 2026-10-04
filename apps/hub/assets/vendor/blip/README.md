# Blip, vendored

`tokens.css` and `blip.css` are copied unchanged from the Blip brand kit
(`brand/` in the blip repo, commit 617c74b). The avatar markup from
`brand/blip.svg` lives in `PhotonWeb.Blip`, with its gradient and clip IDs
made unique per copy so each Blip on a page can show its own state. The
voice from `brand/VOICE.md` lives in `Photon.Assistant.Prompt`.

To update, copy the two CSS files again, carry any change to `blip.svg` into
`PhotonWeb.Blip`, and update the commit above.
