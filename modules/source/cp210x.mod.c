#include <linux/module.h>
#include <linux/vermagic.h>
#include <linux/compiler.h>

MODULE_INFO(vermagic, VERMAGIC_STRING);

struct module __this_module
__attribute__((section(".gnu.linkonce.this_module"))) = {
	.name = KBUILD_MODNAME,
	.init = init_module,
#ifdef CONFIG_MODULE_UNLOAD
	.exit = cleanup_module,
#endif
	.arch = MODULE_ARCH_INIT,
};

static const struct modversion_info ____versions[]
__used
__attribute__((section("__versions"))) = {
	{ 0x68ee78b9, __VMLINUX_SYMBOL_STR(module_layout) },
	{ 0xb8dd67c5, __VMLINUX_SYMBOL_STR(usb_serial_deregister_drivers) },
	{ 0x8e0ae475, __VMLINUX_SYMBOL_STR(usb_serial_register_drivers) },
	{ 0x460e606f, __VMLINUX_SYMBOL_STR(usb_serial_generic_open) },
	{ 0x751bb41f, __VMLINUX_SYMBOL_STR(usb_serial_generic_close) },
	{ 0x468ee2a8, __VMLINUX_SYMBOL_STR(tty_encode_baud_rate) },
	{ 0x1c89523a, __VMLINUX_SYMBOL_STR(usb_reset_device) },
	{ 0xe36d8f83, __VMLINUX_SYMBOL_STR(usb_control_msg) },
	{ 0x12da5bb2, __VMLINUX_SYMBOL_STR(__kmalloc) },
	{ 0x9ac1ca58, __VMLINUX_SYMBOL_STR(kmem_cache_alloc) },
	{ 0x5aef5059, __VMLINUX_SYMBOL_STR(kmalloc_caches) },
	{ 0x037a0cba, __VMLINUX_SYMBOL_STR(kfree) },
	{ 0x1a2bfe0c, __VMLINUX_SYMBOL_STR(dev_err) },
	{ 0x0116bd00, __VMLINUX_SYMBOL_STR(dev_warn) },
	{ 0xefd6cf06, __VMLINUX_SYMBOL_STR(__aeabi_unwind_cpp_pr0) },
};

static const char __module_depends[]
__used
__attribute__((section(".modinfo"))) =
"depends=";
