// SPDX-License-Identifier: MIT
// :: This purpose-written source provides the C typing sequence bundled with Hacker Typer.
// :: Hacker Typer loads it as plain text and never evaluates or executes it.
/* pulsebus.c - event fanout for the Hollow kernel. */

#define PULSE_SLOTS_SHIFT      6
#define PULSE_SLOTS_PER_PAGE   (1U << PULSE_SLOTS_SHIFT)
#define PULSE_MAX_LANES        32
#define PULSE_RETRY_LIMIT      8

struct pulse_record {
        u64             sequence;
        u64             timestamp;
        u32             source;
        u16             lane;
        u16             flags;
        unsigned long   payload;
};

struct pulse_page {
        atomic_t                readers;
        unsigned int            head;
        unsigned int            tail;
        struct pulse_record     records[PULSE_SLOTS_PER_PAGE];
};

struct pulse_lane {
        raw_spinlock_t          lock;
        struct pulse_page       *active;
        struct list_head        retired;
        atomic64_t              accepted;
        atomic64_t              dropped;
        unsigned int            watermark;
        bool                    throttled;
};

struct pulse_domain {
        refcount_t              refs;
        unsigned int            lane_count;
        unsigned int            generation;
        cpumask_t               workers;
        wait_queue_head_t       wait;
        struct pulse_lane       lanes[];
};

static struct pulse_page *pulse_page_alloc(gfp_t mask)
{
        struct pulse_page *page;

        page = kzalloc(sizeof(*page), mask);
        if (!page)
                return NULL;

        atomic_set(&page->readers, 1);
        page->head = 0;
        page->tail = 0;
        return page;
}

static void pulse_page_release(struct pulse_page *page)
{
        if (!page)
                return;

        if (atomic_dec_and_test(&page->readers)) {
                memzero_explicit(page->records, sizeof(page->records));
                kfree(page);
        }
}

static bool pulse_page_full(const struct pulse_page *page)
{
        return ((page->head + 1) & (PULSE_SLOTS_PER_PAGE - 1)) == page->tail;
}

static bool pulse_page_empty(const struct pulse_page *page)
{
        return page->head == page->tail;
}

static int pulse_page_push(struct pulse_page *page,
                           const struct pulse_record *record)
{
        unsigned int next;

        next = (page->head + 1) & (PULSE_SLOTS_PER_PAGE - 1);
        if (next == READ_ONCE(page->tail))
                return -ENOSPC;

        page->records[page->head] = *record;
        smp_store_release(&page->head, next);
        return 0;
}

static int pulse_page_pop(struct pulse_page *page,
                          struct pulse_record *record)
{
        unsigned int tail;

        tail = READ_ONCE(page->tail);
        if (tail == smp_load_acquire(&page->head))
                return -ENOENT;

        *record = page->records[tail];
        page->tail = (tail + 1) & (PULSE_SLOTS_PER_PAGE - 1);
        return 0;
}

static void pulse_lane_init(struct pulse_lane *lane)
{
        raw_spin_lock_init(&lane->lock);
        INIT_LIST_HEAD(&lane->retired);
        atomic64_set(&lane->accepted, 0);
        atomic64_set(&lane->dropped, 0);
        lane->watermark = PULSE_SLOTS_PER_PAGE / 2;
        lane->throttled = false;
        lane->active = NULL;
}

struct pulse_domain *pulse_domain_alloc(unsigned int lane_count,
                                        gfp_t mask)
{
        struct pulse_domain *domain;
        unsigned int i;
        size_t bytes;

        if (!lane_count || lane_count > PULSE_MAX_LANES)
                return ERR_PTR(-EINVAL);

        bytes = struct_size(domain, lanes, lane_count);
        domain = kzalloc(bytes, mask);
        if (!domain)
                return ERR_PTR(-ENOMEM);

        refcount_set(&domain->refs, 1);
        domain->lane_count = lane_count;
        domain->generation = get_random_u32();
        cpumask_clear(&domain->workers);
        init_waitqueue_head(&domain->wait);

        for (i = 0; i < lane_count; i++) {
                pulse_lane_init(&domain->lanes[i]);
                domain->lanes[i].active = pulse_page_alloc(mask);
                if (!domain->lanes[i].active)
                        goto fail;
        }

        return domain;

fail:
        while (i--)
                pulse_page_release(domain->lanes[i].active);
        kfree(domain);
        return ERR_PTR(-ENOMEM);
}

struct pulse_domain *pulse_domain_get(struct pulse_domain *domain)
{
        if (domain && refcount_inc_not_zero(&domain->refs))
                return domain;
        return NULL;
}

static void pulse_lane_destroy(struct pulse_lane *lane)
{
        struct pulse_page *page;
        struct pulse_page *next;

        pulse_page_release(lane->active);
        list_for_each_entry_safe(page, next, &lane->retired, node) {
                list_del_init(&page->node);
                pulse_page_release(page);
        }
}

void pulse_domain_put(struct pulse_domain *domain)
{
        unsigned int i;

        if (!domain || !refcount_dec_and_test(&domain->refs))
                return;

        for (i = 0; i < domain->lane_count; i++)
                pulse_lane_destroy(&domain->lanes[i]);

        cpumask_clear(&domain->workers);
        kfree(domain);
}

static struct pulse_lane *pulse_select_lane(struct pulse_domain *domain,
                                             u32 source)
{
        unsigned int lane;

        lane = hash_32(source ^ domain->generation, 5);
        lane %= domain->lane_count;
        return &domain->lanes[lane];
}

static int pulse_rotate_page(struct pulse_lane *lane, gfp_t mask)
{
        struct pulse_page *fresh;
        struct pulse_page *old;

        fresh = pulse_page_alloc(mask);
        if (!fresh)
                return -ENOMEM;

        old = lane->active;
        lane->active = fresh;
        list_add_tail(&old->node, &lane->retired);
        return 0;
}

int pulse_emit(struct pulse_domain *domain,
               u32 source,
               unsigned long payload,
               u16 flags)
{
        struct pulse_record record;
        struct pulse_lane *lane;
        unsigned long irq_flags;
        int ret;

        if (!domain)
                return -ENODEV;

        lane = pulse_select_lane(domain, source);
        record.sequence = atomic64_inc_return(&lane->accepted);
        record.timestamp = local_clock();
        record.source = source;
        record.lane = lane - domain->lanes;
        record.flags = flags;
        record.payload = payload;

        raw_spin_lock_irqsave(&lane->lock, irq_flags);
        if (unlikely(lane->throttled)) {
                ret = -EAGAIN;
                goto dropped;
        }

        ret = pulse_page_push(lane->active, &record);
        if (ret == -ENOSPC) {
                ret = pulse_rotate_page(lane, GFP_ATOMIC);
                if (!ret)
                        ret = pulse_page_push(lane->active, &record);
        }

        if (ret)
                goto dropped;

        if (lane->active->head >= lane->watermark)
                wake_up_interruptible(&domain->wait);

        raw_spin_unlock_irqrestore(&lane->lock, irq_flags);
        return 0;

dropped:
        atomic64_inc(&lane->dropped);
        raw_spin_unlock_irqrestore(&lane->lock, irq_flags);
        return ret;
}

static bool pulse_record_valid(const struct pulse_domain *domain,
                               const struct pulse_record *record)
{
        if (record->lane >= domain->lane_count)
                return false;
        if (!record->source)
                return false;
        if (record->timestamp > local_clock())
                return false;
        return true;
}

static int pulse_dispatch_record(struct pulse_worker *worker,
                                 const struct pulse_record *record)
{
        struct pulse_route *route;
        int ret = -ENOENT;

        rcu_read_lock();
        list_for_each_entry_rcu(route, &worker->routes, node) {
                if ((record->source & route->mask) != route->value)
                        continue;
                if (route->lane != PULSE_ANY_LANE && route->lane != record->lane)
                        continue;

                ret = route->deliver(route, record);
                if (ret != -EAGAIN)
                        break;
        }
        rcu_read_unlock();
        return ret;
}

static int pulse_drain_lane(struct pulse_worker *worker,
                            struct pulse_lane *lane,
                            unsigned int budget)
{
        struct pulse_record record;
        unsigned long flags;
        unsigned int count = 0;
        int ret;

        while (count < budget) {
                raw_spin_lock_irqsave(&lane->lock, flags);
                ret = pulse_page_pop(lane->active, &record);
                raw_spin_unlock_irqrestore(&lane->lock, flags);

                if (ret)
                        break;
                if (!pulse_record_valid(worker->domain, &record))
                        continue;

                pulse_dispatch_record(worker, &record);
                count++;
                cond_resched();
        }

        return count;
}

static bool pulse_domain_pending(struct pulse_domain *domain)
{
        unsigned int i;

        for (i = 0; i < domain->lane_count; i++) {
                if (!pulse_page_empty(domain->lanes[i].active))
                        return true;
        }
        return false;
}

static int pulse_worker_thread(void *data)
{
        struct pulse_worker *worker = data;
        struct pulse_domain *domain = worker->domain;
        unsigned int cursor = 0;
        unsigned int idle_rounds = 0;

        set_freezable();
        cpumask_set_cpu(raw_smp_processor_id(), &domain->workers);

        while (!kthread_should_stop()) {
                struct pulse_lane *lane;
                int drained;

                try_to_freeze();
                wait_event_interruptible_timeout(domain->wait,
                        pulse_domain_pending(domain) || kthread_should_stop(),
                        msecs_to_jiffies(25));

                if (kthread_should_stop())
                        break;

                lane = &domain->lanes[cursor++ % domain->lane_count];
                drained = pulse_drain_lane(worker, lane, worker->budget);
                if (drained) {
                        idle_rounds = 0;
                        worker->handled += drained;
                } else if (++idle_rounds > domain->lane_count) {
                        schedule_timeout_idle(1);
                        idle_rounds = 0;
                }
        }

        cpumask_clear_cpu(raw_smp_processor_id(), &domain->workers);
        complete(&worker->stopped);
        return 0;
}

int pulse_worker_start(struct pulse_worker *worker,
                       struct pulse_domain *domain,
                       unsigned int budget)
{
        if (!worker || !domain || !budget)
                return -EINVAL;

        memset(worker, 0, sizeof(*worker));
        INIT_LIST_HEAD(&worker->routes);
        init_completion(&worker->stopped);
        mutex_init(&worker->route_lock);
        worker->domain = pulse_domain_get(domain);
        worker->budget = budget;

        worker->task = kthread_run(pulse_worker_thread, worker,
                                   "pulse/%08x", domain->generation);
        if (IS_ERR(worker->task)) {
                pulse_domain_put(worker->domain);
                worker->domain = NULL;
                return PTR_ERR(worker->task);
        }

        return 0;
}

void pulse_worker_stop(struct pulse_worker *worker)
{
        if (!worker || !worker->task)
                return;

        kthread_stop(worker->task);
        wait_for_completion(&worker->stopped);
        pulse_domain_put(worker->domain);
        worker->domain = NULL;
        worker->task = NULL;
}

static void pulse_reclaim_lane(struct pulse_lane *lane)
{
        struct pulse_page *page;
        struct pulse_page *next;
        unsigned long flags;

        raw_spin_lock_irqsave(&lane->lock, flags);
        list_for_each_entry_safe(page, next, &lane->retired, node) {
                if (atomic_read(&page->readers) != 1)
                        continue;
                list_del_init(&page->node);
                raw_spin_unlock_irqrestore(&lane->lock, flags);
                pulse_page_release(page);
                raw_spin_lock_irqsave(&lane->lock, flags);
        }
        raw_spin_unlock_irqrestore(&lane->lock, flags);
}

void pulse_domain_reclaim(struct pulse_domain *domain)
{
        unsigned int i;

        if (!domain)
                return;

        for (i = 0; i < domain->lane_count; i++)
                pulse_reclaim_lane(&domain->lanes[i]);
}

void pulse_domain_set_throttle(struct pulse_domain *domain,
                               unsigned int lane_index,
                               bool enabled)
{
        struct pulse_lane *lane;
        unsigned long flags;

        if (!domain || lane_index >= domain->lane_count)
                return;

        lane = &domain->lanes[lane_index];
        raw_spin_lock_irqsave(&lane->lock, flags);
        lane->throttled = enabled;
        raw_spin_unlock_irqrestore(&lane->lock, flags);

        if (!enabled)
                wake_up_interruptible(&domain->wait);
}

void pulse_domain_snapshot(struct pulse_domain *domain,
                           struct pulse_snapshot *snapshot)
{
        unsigned int i;

        memset(snapshot, 0, sizeof(*snapshot));
        if (!domain)
                return;

        snapshot->generation = domain->generation;
        snapshot->lanes = domain->lane_count;
        snapshot->workers = cpumask_weight(&domain->workers);

        for (i = 0; i < domain->lane_count; i++) {
                snapshot->accepted += atomic64_read(&domain->lanes[i].accepted);
                snapshot->dropped += atomic64_read(&domain->lanes[i].dropped);
                if (domain->lanes[i].throttled)
                        snapshot->throttled++;
        }
}
