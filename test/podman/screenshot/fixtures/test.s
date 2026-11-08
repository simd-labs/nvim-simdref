.text
.globl my_label
my_label:
    vfmadd231ps ymm0, ymm1, ymm2
    vaddps ymm0, ymm0, ymm3
    ret
