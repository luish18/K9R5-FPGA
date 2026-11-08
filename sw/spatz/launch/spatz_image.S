// K9R5: a Spatz cluster program's flat image (SPATZ_BIN), in its own section
// that the Makefile places at the cluster's DRAM window, where the program is
// linked. SPATZ_ENTRY is the program's entry point.

    .section .spatz_image, "a", @progbits
    .globl __spatz_image_start
__spatz_image_start:
    .incbin SPATZ_BIN
    .globl __spatz_image_end
__spatz_image_end:

    .globl __spatz_entry
    .set __spatz_entry, SPATZ_ENTRY
