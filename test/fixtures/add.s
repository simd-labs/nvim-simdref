	.text
	.globl	add_ps
add_ps:
	vaddps	%ymm0, %ymm1, %ymm2
	ret
