GENERATE_SCRIPT=./generate.sh
MODULES_CONF=./modules.conf
GRUB_CONF=./grub.cfg
OUTPUT_FILE=./grubpxe.0


all: ${OUTPUT_FILE}

${OUTPUT_FILE}:
	@${GENERATE_SCRIPT} ${OUTPUT_FILE} ${GRUB_CONF} ${MODULES_CONF}
	@echo ${OUTPUT_FILE} was correctly generated

clean:
	rm ${OUTPUT_FILE}
