#include <linux/kgdb.h>
#include <linux/module.h>
#include <linux/io.h>
#include "kgdboe_io_extension.h"
#include <linux/kdb.h>

int extract_address(const char **input, unsigned long *addr);
int read_physical_address(const char *t_addr);
int write_physical_address(const char *t_addr, const char *t_value);
int force_single_cpu_mode(void);
void save_interrupt_status(void);
void restore_interrupt_status(void);
unsigned long long preempt_count_kgdboe = 0;

/* workaround against certain OS function such as io_remap not allowing functionality in ISR
*  Since all kgdb operation occur in ISR, we can just save and restore __preempt_count to workaround this.
*/
void save_interrupt_status(void)
{
	// Save current preempt count
    preempt_count_kgdboe = preempt_count();
    // ... critical section where preempt count may be changed ...
    // Restore preempt count for current CPU
    this_cpu_write(__preempt_count, 0);
}

void restore_interrupt_status(void)
{
	__preempt_count_add(preempt_count_kgdboe);
}

int extract_address(const char **input, unsigned long *addr)
{
    unsigned long long res;
    char addr_str[32];
    int i = 0;
    const char *ptr;

    if (!input || !*input || !addr)
        return -EINVAL;

    ptr = *input;  // Work on a local copy of the pointer

    // Skip leading spaces
    while (*ptr == ' ')
        ptr++;

    // Copy up to first space or max length
    while (*ptr && *ptr != ' ' && i < (sizeof(addr_str) - 1)) {
        addr_str[i++] = *ptr++;
    }
    addr_str[i] = '\0';

    if (kstrtoull(addr_str, 0, &res))
        return -EINVAL;

    *addr = (unsigned long)res;
    *input = ptr;  // Advance the original pointer (const char **) to new position

    return 0;
}

int read_physical_address(const char *t_addr)
{
    unsigned long addr;
    void __iomem *address_map;
    int ret;
    u32 value;

    ret = extract_address(&t_addr, &addr);
    if (ret) {
        printk(KERN_ERR "Failed to extract address: %d\n", ret);
        return ret;
    }

    // No check for addr == 0, because 0 can be valid.

    save_interrupt_status();
    address_map = ioremap((resource_size_t)addr, 0x4);
    restore_interrupt_status();
    if (!address_map) {
        printk(KERN_ERR "ioremap failed for address: 0x%lx\n", addr);
        return -ENOMEM;
    }

    ret = copy_from_kernel_nofault(&value, (const void __force *)address_map, sizeof(value));
    if (ret) {
        printk(KERN_ERR "copy_from_kernel_nofault failed: %d\n", ret);
        iounmap(address_map);
        return ret;
    }

	kdb_printf("0x%08x\n", value);

    printk(KERN_INFO "Value read from 0x%lx: 0x%08x\n", addr, value);
	
    iounmap(address_map);

    return 0;
}

int write_physical_address(const char *t_addr, const char *t_value)
{
    unsigned long addr;
    void __iomem *address_map;
    int ret;
    unsigned long value;

    ret = extract_address(&t_addr, &addr);
    if (ret) {
        printk(KERN_ERR "Failed to extract address: %d\n", ret);
        return ret;
    }

    ret = extract_address(&t_value, &value);
    if (ret) {
        printk(KERN_ERR "Failed to extract address: %d\n", ret);
        return ret;
    }

    save_interrupt_status();
    address_map = ioremap((resource_size_t)addr, 0x4);
    restore_interrupt_status();
    if (!address_map) {
        printk(KERN_ERR "ioremap failed for address: 0x%lx\n", addr);
        return -ENOMEM;
    }

    writel(value, address_map);  // write 32-bit value

    printk(KERN_INFO "Value 0x%lx written to 0x%lx\n", value, addr);

    iounmap(address_map);
    return 0;
}

/*
 * All kdb shell command call backs receive argc and argv, where
 * argv[0] is the command the end user typed
 */
static int kdb_kgdboe_cmd(int argc, const char **argv)
{
	if (argc < 1)
		return KDB_ARGCOUNT;

	char command = argv[1][0];  // third character
    switch (command) {
        case 'r': {
			return read_physical_address(argv[2]);
        }
        case 'w': {
			return write_physical_address(argv[2], argv[3]);;
        }
        default:
            return KDB_NOTFOUND;  // unknown command
    }
	return 0;
}

static kdbtab_t kgdboe_cmd = {
	.name = "kgdboe",
	.func = kdb_kgdboe_cmd,
	.usage = "[string]",
	.help = "kgdboe GDB Extension utility, refer to Confluence to instruction.",
};


int kgdboe_io_extension_init(void)
{
	kdb_register(&kgdboe_cmd);
	return 0;
}

void kgdboe_io_extension_cleanup(void)
{
	kdb_unregister(&kgdboe_cmd);
}