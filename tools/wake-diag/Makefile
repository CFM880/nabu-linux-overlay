obj-m := nabu-pwrkey-wake.o
# Build with the port's own output tree and, crucially, the same command line
# the pipeline uses, otherwise scripts/setlocalversion appends '+' to the
# vermagic and the module is refused:
#   make -C ../../../linux-6.14 O=../../../nabu-main/out ARCH=arm64 \
#        CROSS_COMPILE=aarch64-linux-gnu- LOCALVERSION= M=$(pwd) modules
