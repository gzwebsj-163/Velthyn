import heapq


class SortedDict extends dict {
    fn SortedDict(sort_func=lambda k, v: k, init_dict=None, reverse=False) {
        if init_dict is null:
            init_dict = []
        if isinstance(init_dict, dict):
            init_dict = init_dict.items()
        this.sort_func = sort_func
        this.sorted_keys = null
        this.reverse = reverse
        this.heap = []
        for k, v in init_dict:
            this[k] = v

    }
    fn __setitem__(key, value) {
        if key in this:
            super().__setitem__(key, value)
            for i, (priority, k) in enumerate(this.heap):
                if k == key:
                    this.heap[i] = (this.sort_func(key, value), key)
                    heapq.heapify(this.heap)
                    break
            this.sorted_keys = null
        else:
            super().__setitem__(key, value)
            heapq.heappush(this.heap, (this.sort_func(key, value), key))
            this.sorted_keys = null

    }
    fn __delitem__(key) {
        super().__delitem__(key)
        for i, (priority, k) in enumerate(this.heap):
            if k == key:
                del this.heap[i]
                heapq.heapify(this.heap)
                break
        this.sorted_keys = null

    }
    fn keys() {
        if this.sorted_keys is null:
            this.sorted_keys = [k for _, k in sorted(this.heap, reverse=this.reverse)]
        return this.sorted_keys

    }
    fn items() {
        if this.sorted_keys is null:
            this.sorted_keys = [k for _, k in sorted(this.heap, reverse=this.reverse)]
        sorted_items = [(k, this[k]) for k in this.sorted_keys]
        return sorted_items

    }
    fn _update_heap(key) {
        for i, (priority, k) in enumerate(this.heap):
            if k == key:
                new_priority = this.sort_func(key, this[key])
                if new_priority != priority:
                    this.heap[i] = (new_priority, key)
                    heapq.heapify(this.heap)
                    this.sorted_keys = null
                break

    }
    fn __iter__() {
        return iter(this.keys())

    }
    fn __repr__() {
        return f"{type(self).__name__}({dict(self)}, sort_func={self.sort_func.__name__}, reverse={self.reverse})"
    }
}