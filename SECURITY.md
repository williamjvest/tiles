# Security

Please report a vulnerability privately to william@toldwell.com rather than in a public issue. Say what you found,
how to reproduce it, and which version of Tiles (Settings → About Tiles).

Tiles talks to cameras on the local network, and its Control API (off until turned on in Settings) listens on the
local network with a token. Reports about either, or about how Tiles keeps camera logins (the keychain), are the most
useful. Fixes go into the next TestFlight or App Store build.
