#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define HANDSHAKE_TIMEOUT_SECONDS 5
#define REAP_TIMEOUT_SECONDS 2

static const char setup_message[] = "bounded verification command setup failed\n";
static const char timeout_message[] = "bounded verification command timed out\n";
static const char usage_message[] =
    "usage: bounded-runner TIMEOUT_SECONDS GRACE_SECONDS -- COMMAND [ARG ...]\n";

static volatile sig_atomic_t received_signal = 0;
static int signal_write_fd = -1;

static void handle_signal(int signal_number) {
  const unsigned char byte = (unsigned char)signal_number;
  const int saved_errno = errno;

  if (received_signal == 0) {
    received_signal = signal_number;
  }
  if (signal_write_fd >= 0) {
    (void)write(signal_write_fd, &byte, sizeof(byte));
  }
  errno = saved_errno;
}

static int write_all(int file_descriptor, const void *buffer, size_t length) {
  const unsigned char *cursor = buffer;

  while (length > 0U) {
    const ssize_t written = write(file_descriptor, cursor, length);
    if (written > 0) {
      cursor += (size_t)written;
      length -= (size_t)written;
      continue;
    }
    if (written < 0 && errno == EINTR) {
      continue;
    }
    return -1;
  }
  return 0;
}

static int read_all(int file_descriptor, void *buffer, size_t length) {
  unsigned char *cursor = buffer;

  while (length > 0U) {
    const ssize_t bytes_read = read(file_descriptor, cursor, length);
    if (bytes_read > 0) {
      cursor += (size_t)bytes_read;
      length -= (size_t)bytes_read;
      continue;
    }
    if (bytes_read < 0 && errno == EINTR) {
      continue;
    }
    return -1;
  }
  return 0;
}

static int read_exec_error(int file_descriptor) {
  int exec_error;

  for (;;) {
    const ssize_t bytes_read = read(file_descriptor, &exec_error, sizeof(exec_error));
    if (bytes_read == 0) {
      return 0;
    }
    if (bytes_read > 0) {
      return 1;
    }
    if (errno != EINTR) {
      return -1;
    }
  }
}

static int monotonic_now(struct timespec *current_time) {
  return clock_gettime(CLOCK_MONOTONIC, current_time);
}

static double seconds_between(const struct timespec *start,
                              const struct timespec *end) {
  const double seconds = (double)(end->tv_sec - start->tv_sec);
  const double nanoseconds = (double)(end->tv_nsec - start->tv_nsec) / 1.0e9;
  return seconds + nanoseconds;
}

static int remaining_milliseconds(const struct timespec *start,
                                  long duration_seconds) {
  struct timespec current_time;
  double remaining;

  if (monotonic_now(&current_time) != 0) {
    return -1;
  }
  remaining = (double)duration_seconds - seconds_between(start, &current_time);
  if (remaining <= 0.0) {
    return 0;
  }
  if (remaining >= (double)INT_MAX / 1000.0) {
    return INT_MAX;
  }
  return (int)(remaining * 1000.0) + 1;
}

static int set_close_on_exec(int file_descriptor) {
  const int flags = fcntl(file_descriptor, F_GETFD);

  if (flags < 0) {
    return -1;
  }
  return fcntl(file_descriptor, F_SETFD, flags | FD_CLOEXEC);
}

static int set_nonblocking(int file_descriptor) {
  const int flags = fcntl(file_descriptor, F_GETFL);

  if (flags < 0) {
    return -1;
  }
  return fcntl(file_descriptor, F_SETFL, flags | O_NONBLOCK);
}

static void close_if_open(int *file_descriptor) {
  if (*file_descriptor >= 0) {
    (void)close(*file_descriptor);
    *file_descriptor = -1;
  }
}

static int install_outer_signal_handlers(void) {
  struct sigaction action;

  memset(&action, 0, sizeof(action));
  action.sa_handler = handle_signal;
  if (sigemptyset(&action.sa_mask) != 0) {
    return -1;
  }
  if (sigaction(SIGINT, &action, NULL) != 0 ||
      sigaction(SIGTERM, &action, NULL) != 0) {
    return -1;
  }
  return 0;
}

static int set_sentinel_signal_dispositions(void) {
  struct sigaction action;

  memset(&action, 0, sizeof(action));
  action.sa_handler = SIG_IGN;
  if (sigemptyset(&action.sa_mask) != 0) {
    return -1;
  }
  if (sigaction(SIGINT, &action, NULL) != 0 ||
      sigaction(SIGTERM, &action, NULL) != 0) {
    return -1;
  }
  return 0;
}

static int reset_command_signal_dispositions(void) {
  struct sigaction action;

  memset(&action, 0, sizeof(action));
  action.sa_handler = SIG_DFL;
  if (sigemptyset(&action.sa_mask) != 0) {
    return -1;
  }
  if (sigaction(SIGINT, &action, NULL) != 0 ||
      sigaction(SIGTERM, &action, NULL) != 0) {
    return -1;
  }
  return 0;
}

static void wait_forever(void) {
  for (;;) {
    (void)pause();
  }
}

static void sentinel_main(int ready_fd, int control_fd, int status_fd,
                          char *const command_argv[]) {
  char protocol_byte;
  int exec_pipe[2] = {-1, -1};
  pid_t command_pid;
  int command_status;

  signal_write_fd = -1;
  if (set_sentinel_signal_dispositions() != 0 || setpgid(0, 0) != 0) {
    protocol_byte = 'F';
    (void)write_all(ready_fd, &protocol_byte, sizeof(protocol_byte));
    _exit(1);
  }

  protocol_byte = 'G';
  if (write_all(ready_fd, &protocol_byte, sizeof(protocol_byte)) != 0 ||
      read_all(control_fd, &protocol_byte, sizeof(protocol_byte)) != 0 ||
      protocol_byte != 'G') {
    _exit(1);
  }

#ifdef BOUNDED_RUNNER_TEST_HANDSHAKE_FAILURE
  protocol_byte = 'F';
  (void)write_all(ready_fd, &protocol_byte, sizeof(protocol_byte));
  wait_forever();
#endif

  if (pipe(exec_pipe) != 0 || set_close_on_exec(exec_pipe[1]) != 0) {
    protocol_byte = 'F';
    (void)write_all(ready_fd, &protocol_byte, sizeof(protocol_byte));
    wait_forever();
  }

  command_pid = fork();
  if (command_pid < 0) {
    protocol_byte = 'F';
    (void)write_all(ready_fd, &protocol_byte, sizeof(protocol_byte));
    close_if_open(&exec_pipe[0]);
    close_if_open(&exec_pipe[1]);
    wait_forever();
  }
  if (command_pid == 0) {
    close_if_open(&exec_pipe[0]);
    (void)close(ready_fd);
    (void)close(control_fd);
    (void)close(status_fd);
    if (reset_command_signal_dispositions() != 0) {
      const int exec_error = errno;
      (void)write_all(exec_pipe[1], &exec_error, sizeof(exec_error));
      _exit(127);
    }
    execvp(command_argv[0], command_argv);
    {
      const int exec_error = errno;
      (void)write_all(exec_pipe[1], &exec_error, sizeof(exec_error));
    }
    _exit(127);
  }

  close_if_open(&exec_pipe[1]);
  if (read_exec_error(exec_pipe[0]) != 0) {
    while (waitpid(command_pid, &command_status, 0) < 0 && errno == EINTR) {
    }
    protocol_byte = 'F';
    (void)write_all(ready_fd, &protocol_byte, sizeof(protocol_byte));
    close_if_open(&exec_pipe[0]);
    wait_forever();
  }
  close_if_open(&exec_pipe[0]);

  protocol_byte = 'R';
  if (write_all(ready_fd, &protocol_byte, sizeof(protocol_byte)) != 0) {
    wait_forever();
  }
  (void)close(ready_fd);
  (void)close(control_fd);

  while (waitpid(command_pid, &command_status, 0) < 0) {
    if (errno != EINTR) {
      wait_forever();
    }
  }
  (void)write_all(status_fd, &command_status, sizeof(command_status));
  (void)close(status_fd);
  wait_forever();
}

static int wait_for_sentinel(pid_t sentinel_pid, long timeout_seconds) {
  struct timespec start;

  if (monotonic_now(&start) != 0) {
    return -1;
  }
  for (;;) {
    int status;
    const pid_t waited = waitpid(sentinel_pid, &status, WNOHANG);
    struct timespec pause_duration = {0, 10000000L};

    if (waited == sentinel_pid) {
      return 0;
    }
    if (waited < 0) {
      return errno == ECHILD ? 0 : -1;
    }
    if (remaining_milliseconds(&start, timeout_seconds) <= 0) {
      return -1;
    }
    while (nanosleep(&pause_duration, &pause_duration) != 0 && errno == EINTR) {
    }
  }
}

static int cleanup_owned(pid_t sentinel_pid, int group_established,
                         long grace_seconds, int use_grace) {
  struct timespec grace_start;
  int cleanup_failed = 0;

  if (group_established != 0) {
    if (use_grace != 0) {
      if (kill(-sentinel_pid, SIGTERM) != 0 && errno != ESRCH) {
        cleanup_failed = 1;
      }
      if (monotonic_now(&grace_start) != 0) {
        cleanup_failed = 1;
      } else {
        while (remaining_milliseconds(&grace_start, grace_seconds) > 0) {
          struct timespec pause_duration = {0, 10000000L};
          while (nanosleep(&pause_duration, &pause_duration) != 0 &&
                 errno == EINTR) {
          }
        }
      }
    }
    if (kill(-sentinel_pid, SIGKILL) != 0 && errno != ESRCH) {
      cleanup_failed = 1;
    }
  } else if (kill(sentinel_pid, SIGKILL) != 0 && errno != ESRCH) {
    cleanup_failed = 1;
  }

  if (wait_for_sentinel(sentinel_pid, REAP_TIMEOUT_SECONDS) != 0) {
    cleanup_failed = 1;
  }
  return cleanup_failed == 0 ? 0 : -1;
}

static int wait_for_protocol_byte(int ready_fd, int signal_fd,
                                  const struct timespec *start,
                                  char *protocol_byte) {
  for (;;) {
    struct pollfd descriptors[2];
    const int timeout = remaining_milliseconds(start, HANDSHAKE_TIMEOUT_SECONDS);
    int poll_result;

    if (timeout <= 0) {
      return -1;
    }
    descriptors[0].fd = ready_fd;
    descriptors[0].events = POLLIN;
    descriptors[0].revents = 0;
    descriptors[1].fd = signal_fd;
    descriptors[1].events = POLLIN;
    descriptors[1].revents = 0;
    poll_result = poll(descriptors, 2, timeout);
    if (poll_result < 0 && errno == EINTR) {
      if (received_signal != 0) {
        return 1;
      }
      continue;
    }
    if (poll_result <= 0) {
      return -1;
    }
    if ((descriptors[1].revents & POLLIN) != 0 || received_signal != 0) {
      return 1;
    }
    if ((descriptors[0].revents & POLLIN) != 0) {
      return read_all(ready_fd, protocol_byte, sizeof(*protocol_byte));
    }
    if ((descriptors[0].revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
      return -1;
    }
  }
}

static int parse_seconds(const char *text, long *seconds) {
  char *end = NULL;
  long parsed;

  errno = 0;
  parsed = strtol(text, &end, 10);
  if (errno != 0 || end == text || *end != '\0' || parsed < 0 ||
      parsed > INT_MAX) {
    return -1;
  }
  *seconds = parsed;
  return 0;
}

static int command_exit_code(int command_status) {
  if (WIFEXITED(command_status)) {
    return WEXITSTATUS(command_status);
  }
  if (WIFSIGNALED(command_status)) {
    const int result = 128 + WTERMSIG(command_status);
    return result > 255 ? 255 : result;
  }
  return 1;
}

int main(int argc, char *argv[]) {
  long timeout_seconds;
  long grace_seconds;
  int ready_pipe[2] = {-1, -1};
  int control_pipe[2] = {-1, -1};
  int status_pipe[2] = {-1, -1};
  int signal_pipe[2] = {-1, -1};
  pid_t sentinel_pid;
  int group_established = 0;
  struct timespec handshake_start;
  struct timespec command_start;
  char protocol_byte;
  int command_status;

  if (argc < 5 || strcmp(argv[3], "--") != 0 || argv[4] == NULL ||
      parse_seconds(argv[1], &timeout_seconds) != 0 ||
      parse_seconds(argv[2], &grace_seconds) != 0) {
    (void)write_all(STDERR_FILENO, usage_message, sizeof(usage_message) - 1U);
    return 2;
  }
  if (pipe(ready_pipe) != 0 || pipe(control_pipe) != 0 ||
      pipe(status_pipe) != 0 || pipe(signal_pipe) != 0 ||
      set_nonblocking(signal_pipe[0]) != 0 ||
      set_nonblocking(signal_pipe[1]) != 0) {
    (void)write_all(STDERR_FILENO, setup_message, sizeof(setup_message) - 1U);
    return 1;
  }
  signal_write_fd = signal_pipe[1];
  if (install_outer_signal_handlers() != 0 || monotonic_now(&handshake_start) != 0) {
    (void)write_all(STDERR_FILENO, setup_message, sizeof(setup_message) - 1U);
    return 1;
  }

  sentinel_pid = fork();
  if (sentinel_pid < 0) {
    (void)write_all(STDERR_FILENO, setup_message, sizeof(setup_message) - 1U);
    return 1;
  }
  if (sentinel_pid == 0) {
    close_if_open(&ready_pipe[0]);
    close_if_open(&control_pipe[1]);
    close_if_open(&status_pipe[0]);
    close_if_open(&signal_pipe[0]);
    close_if_open(&signal_pipe[1]);
    sentinel_main(ready_pipe[1], control_pipe[0], status_pipe[1], &argv[4]);
    _exit(1);
  }

  close_if_open(&ready_pipe[1]);
  close_if_open(&control_pipe[0]);
  close_if_open(&status_pipe[1]);

  if (wait_for_protocol_byte(ready_pipe[0], signal_pipe[0], &handshake_start,
                             &protocol_byte) != 0 ||
      protocol_byte != 'G') {
    const int interrupted_signal = received_signal;
    (void)cleanup_owned(sentinel_pid, 0, 0, 0);
    if (interrupted_signal != 0) {
      return 128 + interrupted_signal;
    }
    (void)write_all(STDERR_FILENO, setup_message, sizeof(setup_message) - 1U);
    return 1;
  }
  group_established = 1;
  protocol_byte = 'G';
  if (write_all(control_pipe[1], &protocol_byte, sizeof(protocol_byte)) != 0 ||
      wait_for_protocol_byte(ready_pipe[0], signal_pipe[0], &handshake_start,
                             &protocol_byte) != 0 ||
      protocol_byte != 'R') {
    const int interrupted_signal = received_signal;
    (void)cleanup_owned(sentinel_pid, group_established, 0, 0);
    if (interrupted_signal != 0) {
      return 128 + interrupted_signal;
    }
    (void)write_all(STDERR_FILENO, setup_message, sizeof(setup_message) - 1U);
    return 1;
  }
  close_if_open(&ready_pipe[0]);
  close_if_open(&control_pipe[1]);

  if (monotonic_now(&command_start) != 0) {
    (void)cleanup_owned(sentinel_pid, group_established, 0, 0);
    (void)write_all(STDERR_FILENO, setup_message, sizeof(setup_message) - 1U);
    return 1;
  }

  for (;;) {
    struct pollfd descriptors[2];
    const int poll_timeout = remaining_milliseconds(&command_start, timeout_seconds);
    int poll_result;

    if (poll_timeout < 0) {
      (void)cleanup_owned(sentinel_pid, group_established, 0, 0);
      (void)write_all(STDERR_FILENO, setup_message, sizeof(setup_message) - 1U);
      return 1;
    }
    if (poll_timeout == 0) {
      (void)cleanup_owned(sentinel_pid, group_established, grace_seconds, 1);
      (void)write_all(STDERR_FILENO, timeout_message,
                      sizeof(timeout_message) - 1U);
      return 1;
    }

    descriptors[0].fd = status_pipe[0];
    descriptors[0].events = POLLIN;
    descriptors[0].revents = 0;
    descriptors[1].fd = signal_pipe[0];
    descriptors[1].events = POLLIN;
    descriptors[1].revents = 0;
    poll_result = poll(descriptors, 2, poll_timeout);
    if (poll_result < 0 && errno == EINTR) {
      if (received_signal == 0) {
        continue;
      }
    } else if (poll_result < 0) {
      (void)cleanup_owned(sentinel_pid, group_established, 0, 0);
      (void)write_all(STDERR_FILENO, setup_message, sizeof(setup_message) - 1U);
      return 1;
    } else if (poll_result == 0) {
      (void)cleanup_owned(sentinel_pid, group_established, grace_seconds, 1);
      (void)write_all(STDERR_FILENO, timeout_message,
                      sizeof(timeout_message) - 1U);
      return 1;
    }

    if (received_signal != 0 || (descriptors[1].revents & POLLIN) != 0) {
      const int interrupted_signal = received_signal != 0 ? received_signal : SIGTERM;
      (void)cleanup_owned(sentinel_pid, group_established, grace_seconds, 1);
      return 128 + interrupted_signal;
    }
    if ((descriptors[0].revents & POLLIN) != 0) {
      if (read_all(status_pipe[0], &command_status, sizeof(command_status)) != 0) {
        (void)cleanup_owned(sentinel_pid, group_established, 0, 0);
        (void)write_all(STDERR_FILENO, setup_message, sizeof(setup_message) - 1U);
        return 1;
      }
      if (cleanup_owned(sentinel_pid, group_established, 0, 0) != 0) {
        (void)write_all(STDERR_FILENO, setup_message, sizeof(setup_message) - 1U);
        return 1;
      }
      return command_exit_code(command_status);
    }
    if ((descriptors[0].revents & (POLLERR | POLLHUP | POLLNVAL)) != 0) {
      (void)cleanup_owned(sentinel_pid, group_established, 0, 0);
      (void)write_all(STDERR_FILENO, setup_message, sizeof(setup_message) - 1U);
      return 1;
    }
  }
}
