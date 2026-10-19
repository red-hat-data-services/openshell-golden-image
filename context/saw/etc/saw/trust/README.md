Signing trust roots for the SAW installer land in this directory
(e.g. installer-signing.pub).

The verifier (verify-bundle) and these trust roots are baked into the
golden image on purpose: the image must be able to validate the installer
it is handed at VM provisioning, so they cannot arrive on the same disk as
the installer they check. Enforcement mode (off/warn/enforce) is decided by
the installer package, not by the image.

Source: "SAW Golden Image & Installer Architecture". Tracking: RHAI-10799.
