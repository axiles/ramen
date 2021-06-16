// vim: ft=c bs=2 ts=2 sts=2 sw=2 expandtab
/* Ring buffer implementation for Ramen events.
 * Characteristics:
 * - possibly multiple writers but single writer most of the times;
 *
 * - possibly multiple readers but single reader most of the times; When there
 * are several readers we may want each reader to see each tuple or each tuple
 * to be read only once. For the former we will merely use several ring buffer
 * since it's much easier and avoid non-trivial inter blockages.
 *
 * - variable length messages;
 *
 * - the ring buffer is a memory mapped file used for interprocess
 * communications;
 *
 * - when there are multiple readers/writers they are in different processes.
 *
 * Inspired by DPDK ring library, same implementation and same terminology
 * whenever possible.
 */

#ifndef RINGBUF_H_20170606
#define RINGBUF_H_20170606

#include <assert.h>
#include <sys/types.h>
#include <stdatomic.h>
#include <unistd.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <string.h>
#include <limits.h>
#include <time.h>
#include <sched.h>
#include "miscmacs.h"

//#define LOCK_WITH_SPINLOCK
#define LOCK_WITH_LOCKF

/* Set this to flush all data cache lines on the header of the mmapped file: */
//#define NEED_DATA_CACHE_FLUSH
/* Also this to also flush data cache lines on the whole content of the file: */
//#define NEED_DATA_CACHE_FLUSH_ALL

/* Set this to add a full memory barrier: */
//#define NEED_FULL_BARRIER

struct ringbuf_file {
  uint64_t version;  // As a null 0 right-padded ascii string (max 8 chars)
  uint64_t first_seq;
  // Fixed length of the ring buffer. mmapped file must be >= this.
  uint32_t num_words;
  uint32_t wrap:1;  // Does the ring buffer act as a ring?
  // Protects globally prod_* and cons_*. Unused if none of LOCK_WITH_* is defined
  atomic_flag lock;
  /* Pointers to entries. We use uint32 indexes so that we do not have
   * to worry too much about modulos. */
  /* Bytes that are being added by producers lie between prod_tail and
   * prod_head. prod_head points to the next word to be allocated. */
  uint32_t _Atomic prod_head;
  uint32_t _Atomic prod_tail;
  /* Bytes that are being read by consumers are between cons_tail and
   * cons_head. cons_head points to the next word to be read.
   * The ring buffer is empty when prod_tail == cons_head and full whenever
   * prod_head == cons_tail - 1. */
  uint32_t _Atomic cons_head;
  uint32_t _Atomic cons_tail;
  /* We count the number of tuples (actually, of allocations), and keep
   * the range of some observed "t" values: */
  uint32_t _Atomic num_allocs;
  double _Atomic tmin;
  double _Atomic tmax;
  /* For how many seconds to retry writing on NoMoreRoom error
   * (irrelevant for non-wrapping buffers): */
  double timeout;
  /* The actual tuples start here: */
  _Static_assert(ATOMIC_INT_LOCK_FREE,
                 "uint32_t must be lock-free atomics");
  uint32_t _Atomic data[];
};

struct ringbuf {
  struct ringbuf_file *rbf;
  char fname[PATH_MAX];
  size_t mmapped_size;  // The size that was mmapped (for ringbuf_unload)
  /* Only used if LOCK_WITH_LOCKF, but present anyway to keep the same version
   * number: */
  int lock_fd;
};

// Error codes
enum ringbuf_error {
  RB_OK = 0,
  RB_ERR_NO_MORE_ROOM,
  RB_ERR_FAILURE,
  RB_ERR_BAD_VERSION
};

#ifdef NEED_DATA_CACHE_FLUSH
inline void my_cacheflush(void const *p_, size_t sz)
{
  unsigned char const *p = p_;
# define CACHE_LINE 64
  for (size_t i = 0; i < sz; i += CACHE_LINE) {
    asm volatile("clflush (%0)\n\t" : : "r"(p+i) : "memory");
  }
  asm volatile("sfence\n\t" : : : "memory");
}
#endif

// Unlock the head
inline void ringbuf_head_unlock(struct ringbuf *rb)
{
/*  int p = getpid();
  fprintf(stderr, "%d: UNLOCKING, cons:[%d-%d], prod:[%d-%d]\n", p,
          rb->rbf->cons_tail, rb->rbf->cons_head,
          rb->rbf->prod_tail, rb->rbf->prod_head);
  fflush(stderr);*/

# ifdef NEED_DATA_CACHE_FLUSH
  my_cacheflush(rb->rbf, sizeof(*rb->rbf)
#   ifdef NEED_DATA_CACHE_FLUSH_ALL
      + rb->rbf->num_words * sizeof(uint32_t)
#   endif
  );
# endif

# ifdef NEED_FULL_BARRIER
  __sync_synchronize();
# endif

# ifdef LOCK_WITH_LOCKF
  assert(0 == lockf(rb->lock_fd, F_ULOCK, 0));
# else
#   ifdef LOCK_WITH_SPINLOCK
  atomic_flag_clear_explicit(&rb->rbf->lock, memory_order_release);
#   else
  (void)rb;
#   endif
# endif
//  fprintf(stderr, "%d: UNLOCKED\n", p); fflush(stderr);
}

#define ASSUME_KIA_AFTER 1000000UL

inline void ringbuf_head_lock(struct ringbuf *rb)
{
/*  int p = getpid();
  fprintf(stderr, "%d: LOCKING...\n", p); fflush(stderr);*/
# ifdef LOCK_WITH_LOCKF
  assert(0 == lockf(rb->lock_fd, F_LOCK, 0));
# else
#   ifdef LOCK_WITH_SPINLOCK
  /* It doesn't take that long to perform the few pointer changes in the
   * critical section. But there are dangerous assertions in that critical
   * section, so better be prepared: */
  unsigned loops = 0;
  while (atomic_flag_test_and_set_explicit(&rb->rbf->lock, memory_order_acquire)) {
    if (loops++ >= ASSUME_KIA_AFTER / 2) {
      sched_yield();
      if (loops >= ASSUME_KIA_AFTER) {
        fprintf(stderr, "Cannot lock '%s': assuming KIA\n", rb->fname);
        fflush(stderr);
        loops = 0;
        ringbuf_head_unlock(rb);
      }
    }
  }
#   else
  (void)rb;
#   endif
# endif

# ifdef NEED_FULL_BARRIER
  __sync_synchronize();
# endif

# ifdef NEED_DATA_CACHE_FLUSH
  my_cacheflush(rb->rbf, sizeof(*rb->rbf)
#   ifdef NEED_DATA_CACHE_FLUSH_ALL
      + rb->rbf->num_words * sizeof(uint32_t)
#   endif
  );
# endif

/*  fprintf(stderr, "%d: LOCKED, cons:[%d-%d], prod:[%d-%d]\n", p,
          rb->rbf->cons_tail, rb->rbf->cons_head,
          rb->rbf->prod_tail, rb->rbf->prod_head);
  fflush(stderr);*/
}

// Return the number of words currently stored in the ring-buffer:
inline uint32_t ringbuf_file_num_entries(struct ringbuf_file const *rbf, uint32_t prod_tail, uint32_t cons_head)
{
  if (prod_tail >= cons_head) return prod_tail - cons_head;
  return (prod_tail + rbf->num_words) - cons_head;
}

// Conversely, returns the number of words free:
inline uint32_t ringbuf_file_num_free(struct ringbuf_file const *rbf, uint32_t cons_tail, uint32_t prod_head)
{
  if (cons_tail > prod_head) return cons_tail - prod_head - 1;
  return (cons_tail + rbf->num_words) - prod_head - 1;
}

struct ringbuf_tx {
    // Where the record starts (point right after the record length:
    uint32_t record_start;
    // Where the record ends (points to the next record size):
    uint32_t next;
    // The observed prod_head / cons_head
    uint32_t seen;
};

#define PRINT_RB(rb, fmt, ...) do { \
  struct ringbuf_file *rbf = rb->rbf; \
  time_t now = time(NULL); \
  struct tm const *tm = localtime(&now); \
  fprintf(stderr, \
          "%04d-%02d-%02d %02d:%02d:%02d: " \
          "pid=%u, rbf@%p, fname=%s, cons=[%"PRIu32";%"PRIu32"], " \
          "prod=[%"PRIu32";%"PRIu32"], free=%u words: " \
          fmt, \
          tm->tm_year + 1900, tm->tm_mon + 1, tm->tm_mday, \
          tm->tm_hour, tm->tm_min, tm->tm_sec, \
          (unsigned)getpid(), \
          rbf, rb->fname, \
          rbf->cons_tail, rbf->cons_head, \
          rbf->prod_tail, rbf->prod_head, \
          ringbuf_file_num_free(rbf, rbf->prod_tail, rbf->cons_head), \
          __VA_ARGS__); \
  fflush(stderr); \
} while (0)

#define XSTR(x) #x
#define STR(x) XSTR(x)
#define ASSERT_RB(cond) do { \
  if (! (cond)) { \
    PRINT_RB(rb, "Assertion failed: %s, file %s, line %s, function %s.\n", \
             STR(cond), \
             STR(__FILE__), STR(__LINE__), __func__); \
    abort(); \
  } \
} while (0)

extern enum ringbuf_error ringbuf_enqueue_alloc(struct ringbuf *, struct ringbuf_tx *, uint32_t num_words);

extern void ringbuf_enqueue_commit(struct ringbuf *, struct ringbuf_tx const *, double t_start, double t_stop);

extern ssize_t ringbuf_dequeue_alloc(struct ringbuf *, struct ringbuf_tx *);

extern void ringbuf_dequeue_commit(struct ringbuf *, struct ringbuf_tx const *);

// Combine all of the above:
inline enum ringbuf_error ringbuf_enqueue(
      struct ringbuf *rb, uint32_t const *data, uint32_t num_words,
      double t_start, double t_stop)
{
  struct ringbuf_tx tx;
  enum ringbuf_error const err = ringbuf_enqueue_alloc(rb, &tx, num_words);
  if (err) return err;

  struct ringbuf_file *rbf = rb->rbf;

  memcpy(rbf->data + tx.record_start, data, num_words*sizeof(*data));

/*  fprintf(stderr, "%d: write [%d..%d]\n",
          getpid(), tx.record_start, tx.record_start + num_words - 1);*/

  ringbuf_enqueue_commit(rb, &tx, t_start, t_stop);

  return 0;
}

inline ssize_t ringbuf_dequeue(struct ringbuf *rb, uint32_t *data, size_t max_size)
{
  struct ringbuf_tx tx;
  ssize_t const sz = ringbuf_dequeue_alloc(rb, &tx);

  struct ringbuf_file *rbf = rb->rbf;

  if (sz < 0) return sz;
  if ((size_t)sz > max_size) {
    PRINT_RB(rb,
      "Record too big (%zu) to fit in buffer (%zu)\n", sz, max_size);
    return -1;
  }

  memcpy(data, rbf->data + tx.record_start, sz);

  ringbuf_dequeue_commit(rb, &tx);

  return sz;
}

// Initialize the given TX to point to the first record and return its size
// Returns -1 if the file is empty, -2 on error
extern ssize_t ringbuf_read_first(struct ringbuf *, struct ringbuf_tx *);

// Advance the given TX to the next record and return its size,
// or -1 if we've reached the end of what's been written, and 0 on EOF
extern ssize_t ringbuf_read_next(struct ringbuf *, struct ringbuf_tx *);

/* Create a new ring buffer of the specified size. */
extern enum ringbuf_error ringbuf_create(uint64_t version, bool wrap, uint32_t tot_words, double timeout, char const *fname);

/* Mmap the ring buffer present in that file. Fails if the file does not exist
 * already. Returns NULL on error. */
extern enum ringbuf_error ringbuf_load(struct ringbuf *, uint64_t version, char const *fname);

/* Unmap the ringbuffer. */
extern enum ringbuf_error ringbuf_unload(struct ringbuf *);

/* Rotate the underlying disk file: */
extern enum ringbuf_error rotate_file(struct ringbuf *);

/* When one stops/crash with an allocated tx then the ringbuffer will remains
 * unusable (since the next process that tries to commit will wait forever
 * until the cons catch up with the observed head. So whenever it is certain
 * there are no readers and no writers the ringbuffer should be "repaired".
 * In here, it is assumed that what has not been committed was totally lost.
 * Returns true if a fix was indeed necessary. */
bool ringbuf_repair(struct ringbuf *);

#endif
