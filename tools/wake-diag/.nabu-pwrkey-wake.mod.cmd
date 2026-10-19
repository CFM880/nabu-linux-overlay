savedcmd_nabu-pwrkey-wake.mod := printf '%s\n'   nabu-pwrkey-wake.o | awk '!x[$$0]++ { print("./"$$0) }' > nabu-pwrkey-wake.mod
