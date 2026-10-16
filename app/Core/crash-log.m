// 크래시 기록: 시그널과 처리되지 않은 Objective-C 예외를 로그 파일에 남긴다
//
// Mac이 없어 기기의 크래시 리포트를 바로 볼 수 없으므로, 죽기 직전의 스택을 broadcast.log에 직접 쓴다.
// 프레임마다 이미지 이름, 이미지 안의 오프셋(dSYM으로 기호화할 때 쓴다), 가장 가까운 기호를 남긴다.

@import Foundation;

#include "crash-log.h"

#include <dlfcn.h>
#include <execinfo.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int crash_fd = -1;

static void write_text(const char *text)
{
	if (crash_fd >= 0)
		write(crash_fd, text, strlen(text));
	write(STDERR_FILENO, text, strlen(text));
}

static void write_backtrace(void)
{
	void *frames[64];
	int count = backtrace(frames, 64);

	for (int i = 0; i < count; i++) {
		Dl_info info = {0};
		char line[512];

		if (dladdr(frames[i], &info) && info.dli_fname) {
			const char *image = strrchr(info.dli_fname, '/');
			image = image ? image + 1 : info.dli_fname;
			unsigned long offset = (unsigned long)((char *)frames[i] - (char *)info.dli_fbase);

			if (info.dli_sname)
				snprintf(line, sizeof(line), "  %2d %-28s +0x%lx  %s + %lu\n", i, image, offset,
					 info.dli_sname,
					 (unsigned long)((char *)frames[i] - (char *)info.dli_saddr));
			else
				snprintf(line, sizeof(line), "  %2d %-28s +0x%lx\n", i, image, offset);
		} else {
			snprintf(line, sizeof(line), "  %2d %p\n", i, frames[i]);
		}

		write_text(line);
	}
}

static void signal_handler(int signal_number, siginfo_t *info, void *context)
{
	(void)context;

	char line[160];
	snprintf(line, sizeof(line), "\n*** crash: signal %d (%s), address %p ***\n", signal_number,
		 strsignal(signal_number), info ? info->si_addr : NULL);
	write_text(line);
	write_backtrace();
	write_text("*** end of crash ***\n");

	// 기본 동작으로 되돌려 시스템 크래시 리포트도 남게 한다
	signal(signal_number, SIG_DFL);
	raise(signal_number);
}

static void exception_handler(NSException *exception)
{
	NSString *text = [NSString stringWithFormat:@"\n*** uncaught exception %@: %@ ***\n%@\n", exception.name,
						    exception.reason,
						    [exception.callStackSymbols componentsJoinedByString:@"\n"]];
	write_text(text.UTF8String);
}

void crash_log_install(int fd)
{
	crash_fd = fd;

	NSSetUncaughtExceptionHandler(exception_handler);

	struct sigaction action = {0};
	action.sa_sigaction = signal_handler;
	action.sa_flags = SA_SIGINFO;
	sigemptyset(&action.sa_mask);

	const int signals[] = {SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGABRT, SIGTRAP};
	for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); i++)
		sigaction(signals[i], &action, NULL);
}
