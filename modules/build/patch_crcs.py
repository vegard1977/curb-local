import re

CD = '/home/qfh/curb-build/karo-tx-linux'

def patch(filepath, sym_crc_map):
    with open(filepath, 'r') as f:
        content = f.read()
    fixed = 0
    for sym, new_crc in sym_crc_map.items():
        pattern = r'\{ 0x[0-9a-f]+, __VMLINUX_SYMBOL_STR\(' + re.escape(sym) + r'\) \}'
        repl = '{ ' + new_crc + ', __VMLINUX_SYMBOL_STR(' + sym + ') }'
        new_content = re.sub(pattern, repl, content)
        if new_content != content:
            print('  OK: %s -> %s' % (sym, new_crc))
            content = new_content
            fixed += 1
        else:
            print('  SKIP: %s (not found or no change)' % sym)
    with open(filepath, 'w') as f:
        f.write(content)
    print('Fixed %d symbols in %s' % (fixed, filepath))

cdc_fixes = {
    'put_tty_driver':                       '0x9835c30c',
    'tty_unregister_driver':               '0x3fd36581',
    'tty_register_driver':                 '0x3f809ff5',
    'tty_set_operations':                  '0xc2ac74e5',
    '__tty_alloc_driver':                  '0xf0848af2',
    'tty_unregister_device':               '0xba1a35f9',
    'tty_kref_put':                        '0x2e62c319',
    'tty_vhangup':                         '0x906608c7',
    'tty_port_tty_get':                    '0xcd899963',
    'usb_put_intf':                        '0xfa1ddfa8',
    'device_remove_file':                  '0x97607194',
    'tty_port_register_device':            '0xe08bfab6',
    'usb_get_intf':                        '0x1d6016da',
    'tty_port_init':                       '0x2bc7cd30',
    'usb_ifnum_to_if':                     '0xe9b2ff98',
    'tty_flip_buffer_push':                '0x1fd62d6d',
    'tty_insert_flip_string_fixed_flag':   '0xb3221eaa',
    'tty_standard_install':                '0xa073575c',
    'tty_port_open':                       '0xf186dc72',
    'tty_port_close':                      '0x8380de78',
    'usb_anchor_urb':                      '0x9954aa80',
    'tty_port_hangup':                     '0x45c812cd',
    'tty_port_tty_wakeup':                 '0x198bbe57',
    'usb_get_from_anchor':                 '0x8ee78940',
    'tty_port_tty_hangup':                 '0x49932811',
    'tty_port_put':                        '0x3a3106fc',
}

ch341_fixes = {
    'usb_serial_generic_tiocmiwait':       '0xdb070889',
    'usb_serial_deregister_drivers':       '0xb8dd67c5',
    'usb_serial_register_drivers':         '0x8e0ae475',
    'usb_serial_generic_open':             '0x460e606f',
    'tty_kref_put':                        '0x2e62c319',
    'usb_serial_handle_dcd_change':        '0x38fa238d',
    'tty_port_tty_get':                    '0xcd899963',
    'usb_serial_generic_close':            '0x751bb41f',
}

usbserial_fixes = {
    'put_tty_driver':                       '0x9835c30c',
    'tty_unregister_driver':               '0x3fd36581',
    'tty_register_driver':                 '0x3f809ff5',
    'tty_set_operations':                  '0xc2ac74e5',
    '__tty_alloc_driver':                  '0xf0848af2',
    'tty_unregister_device':               '0xba1a35f9',
    'tty_kref_put':                        '0x2e62c319',
    'tty_vhangup':                         '0x906608c7',
    'tty_port_tty_get':                    '0xcd899963',
    'tty_port_tty_wakeup':                 '0x198bbe57',
    'tty_port_tty_hangup':                 '0x49932811',
    'device_remove_file':                  '0x97607194',
    'usb_get_intf':                        '0x1d6016da',
    'usb_put_intf':                        '0xfa1ddfa8',
    'tty_port_init':                       '0x2bc7cd30',
    'tty_flip_buffer_push':                '0x1fd62d6d',
    'tty_insert_flip_string_fixed_flag':   '0xb3221eaa',
    'tty_port_open':                       '0xf186dc72',
    'tty_port_close':                      '0x8380de78',
    'tty_port_hangup':                     '0x45c812cd',
    'tty_register_device':                 '0xf770d77f',
    'tty_ldisc_deref':                     '0x6481759e',
    'tty_ldisc_ref':                       '0x63d62a4a',
    'tty_port_destroy':                    '0x834b4407',
    'tty_insert_flip_string_flags':        '0x450c254a',
    'tty_hangup':                          '0xe1c2e7ab',
    'tty_port_install':                    '0x0354d1c0',
    'usb_poison_urb':                      '0xe1e12831',
    'usb_unpoison_urb':                    '0x2889a336',
    'usb_get_dev':                         '0xd517640f',
    'usb_put_dev':                         '0x413fd915',
    'driver_attach':                       '0x3736fc6d',
    'tty_port_put':                        '0x3a3106fc',
}

print('=== Patching cdc-acm.mod.c ===')
patch(CD + '/drivers/usb/class/cdc-acm.mod.c', cdc_fixes)
print()
print('=== Patching ch341.mod.c ===')
patch(CD + '/drivers/usb/serial/ch341.mod.c', ch341_fixes)
print()
print('=== Patching usbserial.mod.c ===')
patch(CD + '/drivers/usb/serial/usbserial.mod.c', usbserial_fixes)
print()
print('All patches done!')
