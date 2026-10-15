/******************************************************************************
    iOS port of obs-cocoa.m.

    iPadOS has no global hotkeys, no plugin bundles and no AppKit/Carbon/IOKit,
    so this only implements what libobs expects from its platform layer.

    This program is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 2 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program.  If not, see <http://www.gnu.org/licenses/>.
******************************************************************************/

#include "util/dstr.h"
#include "obs.h"
#include "obs-internal.h"

#include <os/proc.h>
#include <sys/sysctl.h>

#import <Foundation/Foundation.h>

// MARK: Module and Data Paths

const char *get_module_extension(void)
{
    return "";
}

void add_default_module_paths(void)
{
    /* Modules are linked statically and registered with obs_open_static_module(). */
}

char *find_libobs_data_file(const char *file)
{
    /* libobs data files are bundled at <App>.app/libobs/. Returning NULL lets
     * obs_find_data_file() fall back to paths added with obs_add_data_path(). */
    NSString *path = [[[NSBundle mainBundle] resourcePath] stringByAppendingFormat:@"/libobs/%s", file];

    if (![[NSFileManager defaultManager] fileExistsAtPath:path])
        return NULL;

    return bstrdup(path.UTF8String);
}

// MARK: - System Info

static void log_sysctl_string(const char *label, const char *name)
{
    char value[256];
    size_t size = sizeof(value);

    if (sysctlbyname(name, value, &size, NULL, 0) == 0)
        blog(LOG_INFO, "%s: %s", label, value);
}

void log_system_info(void)
{
    NSProcessInfo *pi = [NSProcessInfo processInfo];

    log_sysctl_string("Model Identifier", "hw.machine");
    log_sysctl_string("Hardware Model", "hw.model");
    blog(LOG_INFO, "Physical Cores: %d, Logical Cores: %d", os_get_physical_cores(), os_get_logical_cores());
    blog(LOG_INFO, "Physical Memory: %lluMB Total", (unsigned long long) (os_get_sys_total_size() / 1024 / 1024));
    blog(LOG_INFO, "Available Memory: %lluMB (os_proc_available_memory)",
         (unsigned long long) (os_proc_available_memory() / 1024 / 1024));
#if TARGET_OS_SIMULATOR
    blog(LOG_INFO, "OS Name: iOS Simulator");
#else
    blog(LOG_INFO, "OS Name: iPadOS");
#endif
    blog(LOG_INFO, "OS Version: %s", pi.operatingSystemVersionString.UTF8String);
    log_sysctl_string("Kernel Version", "kern.osrelease");
    blog(LOG_INFO, "Low Power Mode: %s", pi.lowPowerModeEnabled ? "on" : "off");
}

// MARK: - Graphics Thread Wrappers

void *obs_graphics_thread_autorelease(void *param)
{
    @autoreleasepool {
        return obs_graphics_thread(param);
    }
}

bool obs_graphics_thread_loop_autorelease(struct obs_graphics_context *context)
{
    @autoreleasepool {
        return obs_graphics_thread_loop(context);
    }
}

// MARK: - Audio Monitoring

/* Referenced by obs-source.c on Apple platforms. iOS uses the null audio
 * monitoring backend, so there is no default monitoring device. */
void get_desktop_default_id(char **p_id)
{
    *p_id = NULL;
}

// MARK: - Hotkeys

/* There are no global hotkeys on iPadOS. The hotkey system still runs, it
 * just never sees a key press. */

bool obs_hotkeys_platform_init(struct obs_core_hotkeys *hotkeys)
{
    hotkeys->platform_context = NULL;
    return true;
}

void obs_hotkeys_platform_free(struct obs_core_hotkeys *hotkeys)
{
    UNUSED_PARAMETER(hotkeys);
}

bool obs_hotkeys_platform_is_pressed(obs_hotkeys_platform_t *context, obs_key_t key)
{
    UNUSED_PARAMETER(context);
    UNUSED_PARAMETER(key);
    return false;
}

int obs_key_to_virtual_key(obs_key_t key)
{
    UNUSED_PARAMETER(key);
    return 0;
}

obs_key_t obs_key_from_virtual_key(int code)
{
    UNUSED_PARAMETER(code);
    return OBS_KEY_NONE;
}

void obs_key_to_str(obs_key_t key, struct dstr *str)
{
    dstr_copy(str, obs_key_to_name(key));
}

void obs_key_combination_to_str(obs_key_combination_t combination, struct dstr *str)
{
    struct dstr key_str = {0};

    if (combination.key != OBS_KEY_NONE)
        obs_key_to_str(combination.key, &key_str);

    dstr_printf(str, "%s%s%s%s%s", (combination.modifiers & INTERACT_CONTROL_KEY) ? "Ctrl+" : "",
                (combination.modifiers & INTERACT_ALT_KEY) ? "Option+" : "",
                (combination.modifiers & INTERACT_SHIFT_KEY) ? "Shift+" : "",
                (combination.modifiers & INTERACT_COMMAND_KEY) ? "Cmd+" : "", key_str.len ? key_str.array : "");

    dstr_free(&key_str);
}
