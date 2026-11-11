# BORE 6.6 wide-compat pin matrix

pins tested: 34; failures: 0

| pin | A vendored (expect=logs) | B unified core | C compat ladder | D post-checks |
|---|---|---|---|---|
| 6.6.46 | A(current)=red:kernel/fork.c,scripts/setlocalversion | B(core)=green | C(compat)=green | D(post)=green |
| 6.6.50 | A(current)=red:kernel/fork.c,scripts/setlocalversion | B(core)=green | C(compat)=green | D(post)=green |
| 6.6.56 | A(current)=red:kernel/fork.c,scripts/setlocalversion | B(core)=green | C(compat)=green | D(post)=green |
| 6.6.57 | A(current)=red:kernel/fork.c,scripts/setlocalversion | B(core)=green | C(compat)=green | D(post)=green |
| 6.6.58 | A(current)=red:kernel/fork.c,scripts/setlocalversion | B(core)=green | C(compat)=green | D(post)=green |
| 6.6.66 | A(current)=green | B(core)=green | C(compat)=green | D(post)=green |
| 6.6.76 | A(current)=green | B(core)=green | C(compat)=green | D(post)=green |
| 6.6.77 | A(current)=green | B(core)=green | C(compat)=green | D(post)=green |
| 6.6.82 | A(current)=green | B(core)=green | C(compat)=green | D(post)=green |
| 6.6.87 | A(current)=green | B(core)=green | C(compat)=green | D(post)=green |
| 6.6.89 | A(current)=green | B(core)=green | C(compat)=green | D(post)=green |
| 6.6.92 | A(current)=red:kernel/sched/fair.c | B(core)=green | C(compat)=green | D(post)=green |
| 6.6.98 | A(current)=red:kernel/sched/fair.c | B(core)=green | C(compat)=green | D(post)=green |
| 6.6.100 | A(current)=red:kernel/sched/fair.c | B(core)=green | C(compat)=green | D(post)=green |
| 6.6.102 | A(current)=red:include/linux/sched.h,kernel/fork.c,kernel/sched/fair.c | B(core)=green | C(compat)=green | D(post)=green |
| 6.6.111 | A(current)=red:include/linux/sched.h,kernel/fork.c,kernel/sched/fair.c | B(core)=green | C(compat)=green | D(post)=green |
| 6.6.116 | A(current)=red:include/linux/sched.h,kernel/fork.c,kernel/sched/fair.c | B(core)=green | C(compat)=green | D(post)=green |
| 6.6.118 | A(current)=red:include/linux/sched.h,kernel/fork.c,kernel/sched/fair.c | B(core)=green | C(compat)=green | D(post)=green |
| 6.6.119 | A(current)=red:include/linux/sched.h,kernel/fork.c,kernel/sched/fair.c | B(core)=green | C(compat)=green | D(post)=green |
| 6.6.123 | A(current)=red:include/linux/sched.h,kernel/fork.c,kernel/sched/fair.c | B(core)=green | C(compat)=green | D(post)=green |
| 6.6.127 | A(current)=red:include/linux/sched.h,kernel/fork.c,kernel/sched/fair.c | B(core)=green | C(compat)=green | D(post)=green |
| 6.6.129 | A(current)=red:include/linux/sched.h,kernel/fork.c,kernel/sched/fair.c | B(core)=green | C(compat)=green | D(post)=green |
| 6.6.138 | A(current)=red:include/linux/sched.h,kernel/fork.c,kernel/sched/fair.c | B(core)=green | C(compat)=green | D(post)=green |
| 6.6.139 | A(current)=red:include/linux/sched.h,kernel/fork.c,kernel/sched/fair.c | B(core)=green | C(compat)=green | D(post)=green |
| 6.6.142 | A(current)=red:include/linux/sched.h,kernel/fork.c,kernel/sched/fair.c | B(core)=green | C(compat)=green | D(post)=green |
| 6.6.143 | A(current)=red:include/linux/sched.h,kernel/fork.c,kernel/sched/fair.c | B(core)=green | C(compat)=green | D(post)=green |
| 6.6.144 | A(current)=red:include/linux/sched.h,kernel/fork.c,kernel/sched/fair.c | B(core)=green | C(compat)=green | D(post)=green |
| branch-2025-09 | A(current)=red:include/linux/sched.h,kernel/fork.c,kernel/sched/fair.c | B(core)=green | C(compat)=green | D(post)=green |
| branch-2025-10 | A(current)=red:include/linux/sched.h,kernel/fork.c,kernel/sched/fair.c | B(core)=green | C(compat)=green | D(post)=green |
| branch-2026-01 | A(current)=red:include/linux/sched.h,kernel/fork.c,kernel/sched/fair.c | B(core)=green | C(compat)=green | D(post)=green |
| branch-2026-04 | A(current)=red:include/linux/sched.h,kernel/fork.c,kernel/sched/fair.c | B(core)=green | C(compat)=green | D(post)=green |
| branch-2026-07 | A(current)=red:include/linux/sched.h,kernel/fork.c,kernel/sched/fair.c | B(core)=green | C(compat)=green | D(post)=green |
| branch-2026-10 | A(current)=red:include/linux/sched.h,kernel/fork.c,kernel/sched/fair.c | B(core)=green | C(compat)=green | D(post)=green |
| branch-lts | A(current)=red:include/linux/sched.h,kernel/fork.c,kernel/sched/fair.c | B(core)=green | C(compat)=green | D(post)=green |

## failures

