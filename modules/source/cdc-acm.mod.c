/*
 * cdc-acm.mod.c — modinfo for cdc-acm.ko (USB CDC ACM driver)
 * Patched .mod.c med Curbs faktiske __kcrctab-CRCer (via patch_crcs.py)
 */
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
	{ 0x63094aea, __VMLINUX_SYMBOL_STR(usb_deregister) },
	{ 0x67b27ec1, __VMLINUX_SYMBOL_STR(tty_std_termios) },
	{ 0x27e1a049, __VMLINUX_SYMBOL_STR(printk) },
	{ 0x9835c30c, __VMLINUX_SYMBOL_STR(put_tty_driver) },
	{ 0x3fd36581, __VMLINUX_SYMBOL_STR(tty_unregister_driver) },
	{ 0xb1a488f6, __VMLINUX_SYMBOL_STR(usb_register_driver) },
	{ 0x3f809ff5, __VMLINUX_SYMBOL_STR(tty_register_driver) },
	{ 0xc2ac74e5, __VMLINUX_SYMBOL_STR(tty_set_operations) },
	{ 0xf0848af2, __VMLINUX_SYMBOL_STR(__tty_alloc_driver) },
	{ 0x71c90087, __VMLINUX_SYMBOL_STR(memcmp) },
	{ 0x409873e3, __VMLINUX_SYMBOL_STR(tty_termios_baud_rate) },
	{ 0xac64efcc, __VMLINUX_SYMBOL_STR(usb_driver_release_interface) },
	{ 0xba1a35f9, __VMLINUX_SYMBOL_STR(tty_unregister_device) },
	{ 0x4205ad24, __VMLINUX_SYMBOL_STR(cancel_work_sync) },
	{ 0x2e62c319, __VMLINUX_SYMBOL_STR(tty_kref_put) },
	{ 0x906608c7, __VMLINUX_SYMBOL_STR(tty_vhangup) },
	{ 0xcd899963, __VMLINUX_SYMBOL_STR(tty_port_tty_get) },
	{ 0xfa1ddfa8, __VMLINUX_SYMBOL_STR(usb_put_intf) },
	{ 0x5aef5059, __VMLINUX_SYMBOL_STR(kmalloc_caches) },
	{ 0x97607194, __VMLINUX_SYMBOL_STR(device_remove_file) },
	{ 0xe08bfab6, __VMLINUX_SYMBOL_STR(tty_port_register_device) },
	{ 0x1d6016da, __VMLINUX_SYMBOL_STR(usb_get_intf) },
	{ 0xf2ff1394, __VMLINUX_SYMBOL_STR(usb_driver_claim_interface) },
	{ 0xe36d8f83, __VMLINUX_SYMBOL_STR(usb_control_msg) },
	{ 0x7b11913f, __VMLINUX_SYMBOL_STR(_dev_info) },
	{ 0x12da5bb2, __VMLINUX_SYMBOL_STR(__kmalloc) },
	{ 0x395bbdb9, __VMLINUX_SYMBOL_STR(device_create_file) },
	{ 0x867c94da, __VMLINUX_SYMBOL_STR(usb_free_urb) },
	{ 0x0116bd00, __VMLINUX_SYMBOL_STR(dev_warn) },
	{ 0x037a0cba, __VMLINUX_SYMBOL_STR(kfree) },
	{ 0xf720aa14, __VMLINUX_SYMBOL_STR(usb_free_coherent) },
	{ 0xd49c06ce, __VMLINUX_SYMBOL_STR(usb_alloc_urb) },
	{ 0xb04354bb, __VMLINUX_SYMBOL_STR(usb_alloc_coherent) },
	{ 0x2bc7cd30, __VMLINUX_SYMBOL_STR(tty_port_init) },
	{ 0xdc798d37, __VMLINUX_SYMBOL_STR(__mutex_init) },
	{ 0x63b87fc5, __VMLINUX_SYMBOL_STR(__init_waitqueue_head) },
	{ 0x9ac1ca58, __VMLINUX_SYMBOL_STR(kmem_cache_alloc) },
	{ 0xe9b2ff98, __VMLINUX_SYMBOL_STR(usb_ifnum_to_if) },
	{ 0x1fd62d6d, __VMLINUX_SYMBOL_STR(tty_flip_buffer_push) },
	{ 0xb3221eaa, __VMLINUX_SYMBOL_STR(tty_insert_flip_string_fixed_flag) },
	{ 0xa073575c, __VMLINUX_SYMBOL_STR(tty_standard_install) },
	{ 0xf186dc72, __VMLINUX_SYMBOL_STR(tty_port_open) },
	{ 0x8380de78, __VMLINUX_SYMBOL_STR(tty_port_close) },
	{ 0x9954aa80, __VMLINUX_SYMBOL_STR(usb_anchor_urb) },
	{ 0xffd5a395, __VMLINUX_SYMBOL_STR(default_wake_function) },
	{ 0x62b72b0d, __VMLINUX_SYMBOL_STR(mutex_unlock) },
	{ 0xc6cbbc89, __VMLINUX_SYMBOL_STR(capable) },
	{ 0xe16b893b, __VMLINUX_SYMBOL_STR(mutex_lock) },
	{ 0xfbc74f64, __VMLINUX_SYMBOL_STR(__copy_from_user) },
	{ 0xa8cde9a7, __VMLINUX_SYMBOL_STR(remove_wait_queue) },
	{ 0x01000e51, __VMLINUX_SYMBOL_STR(schedule) },
	{ 0xfe634f58, __VMLINUX_SYMBOL_STR(add_wait_queue) },
	{ 0x67c2fa54, __VMLINUX_SYMBOL_STR(__copy_to_user) },
	{ 0x0fa2a45e, __VMLINUX_SYMBOL_STR(__memzero) },
	{ 0x45c812cd, __VMLINUX_SYMBOL_STR(tty_port_hangup) },
	{ 0x198bbe57, __VMLINUX_SYMBOL_STR(tty_port_tty_wakeup) },
	{ 0xb35eeab3, __VMLINUX_SYMBOL_STR(usb_kill_urb) },
	{ 0x8ee78940, __VMLINUX_SYMBOL_STR(usb_get_from_anchor) },
	{ 0x676bbc0f, __VMLINUX_SYMBOL_STR(_set_bit) },
	{ 0x2a3aa678, __VMLINUX_SYMBOL_STR(_test_and_clear_bit) },
	{ 0x2d3385d3, __VMLINUX_SYMBOL_STR(system_wq) },
	{ 0xb2d48a2e, __VMLINUX_SYMBOL_STR(queue_work_on) },
	{ 0x49932811, __VMLINUX_SYMBOL_STR(tty_port_tty_hangup) },
	{ 0x43b0c9c3, __VMLINUX_SYMBOL_STR(preempt_schedule) },
	{ 0xb9e52429, __VMLINUX_SYMBOL_STR(__wake_up) },
	{ 0x1a2bfe0c, __VMLINUX_SYMBOL_STR(dev_err) },
	{ 0xbb551af0, __VMLINUX_SYMBOL_STR(usb_submit_urb) },
	{ 0x9d669763, __VMLINUX_SYMBOL_STR(memcpy) },
	{ 0x91715312, __VMLINUX_SYMBOL_STR(sprintf) },
	{ 0x3a3106fc, __VMLINUX_SYMBOL_STR(tty_port_put) },
	{ 0xefd6cf06, __VMLINUX_SYMBOL_STR(__aeabi_unwind_cpp_pr0) },
};

static const char __module_depends[]
__used
__attribute__((section(".modinfo"))) =
"depends=";
