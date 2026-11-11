Always build after each change done to Catwalk.

On Windows, build with `./tools/build-when-closed.sh` (run it in the background), not
`./tools/windows.sh build` directly. Catwalk is often open, and then the link can't
replace catwalk.exe. The script builds into `build\catwalk.exe` instead and returns as
soon as the build is done. If Catwalk is closed it copies the build over catwalk.exe at
once; if Catwalk is open, a hidden PowerShell process waits for it to exit and copies it
then (results in `build\copy.log`). It stops with the compiler's output (exit code 1)
when the code itself doesn't build: fix that, then run it again. Tell the user when the
new build is waiting for Catwalk to close.
