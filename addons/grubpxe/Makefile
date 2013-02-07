GENERATE_SCRIPT=./generate.sh
MODULES_CONF=./modules.conf
GRUB_CONF=./grub.cfg
GRUB_VERSION=2.00
OUTPUT_FILE=./grubpxe.0


all: ${OUTPUT_FILE}

${OUTPUT_FILE}:
	@${GENERATE_SCRIPT} ${OUTPUT_FILE} ${GRUB_CONF} ${MODULES_CONF}-${GRUB_VERSION}
	@echo ${OUTPUT_FILE} was correctly generated for GRUB ${GRUB_VERSION}

1.99:
	@${GENERATE_SCRIPT} ${OUTPUT_FILE} ${GRUB_CONF} ${MODULES_CONF}-1.99
	@echo ${OUTPUT_FILE} was correctly generated for GRUB ${GRUB_VERSION}

2.00:
	@${GENERATE_SCRIPT} ${OUTPUT_FILE} ${GRUB_CONF} ${MODULES_CONF}-2.00
	@echo ${OUTPUT_FILE} was correctly generated for GRUB ${GRUB_VERSION}

clean:
	rm -f ${OUTPUT_FILE}
