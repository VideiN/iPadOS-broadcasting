// 크래시 기록 (crash-log.m)

#pragma once

// 시그널(SIGSEGV 등)과 처리되지 않은 Objective-C 예외가 나면 스택을 fd(로그 파일)와 stderr에 쓴다
void crash_log_install(int fd);
