# Build qemu
FROM debian:stable-slim AS qemu-builder
ARG QEMU_VERSION=5.2.0
COPY build-qemu.sh .
RUN chmod +x build-qemu.sh && ./build-qemu.sh -v $QEMU_VERSION -o /qemu
WORKDIR /qemu
RUN # Strip the binary, this gives a substantial size reduction!
RUN strip "arm-softmmu/qemu-system-arm" "aarch64-softmmu/qemu-system-aarch64"

# Convert filesystem image
FROM qemu-builder AS rpi-image
ADD sdcard.tar.gz /
RUN image_size=`du -m /filesystem.img | cut -f1` && \
    new_size=$(( ( ( ( image_size - 1 ) / 2048 ) + 1 ) * 2 )) && \
    /qemu/qemu-img convert -f raw -O qcow2 /filesystem.img /filesystem.qcow2 && \
    /qemu/qemu-img resize /filesystem.qcow2 "${new_size}G"

# Rpi emulator
FROM busybox:1.31 AS rpi
COPY --from=qemu-builder /qemu/arm-softmmu/qemu-system-arm /usr/local/bin/qemu-system-arm
COPY --from=qemu-builder /qemu/aarch64-softmmu/qemu-system-aarch64 /usr/local/bin/qemu-system-aarch64

COPY --from=rpi-image /rpi.dtb /rpi.dtb 
COPY --from=rpi-image /kernel.img /kernel.img 
COPY --from=rpi-image /filesystem.qcow2 /filesystem.qcow2 
COPY --from=rpi-image /.env /.env

EXPOSE 55555
ADD ./rpi-emulator.sh /rpi.sh
ENTRYPOINT ["./rpi.sh"]

