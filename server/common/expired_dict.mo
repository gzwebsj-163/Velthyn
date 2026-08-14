from datetime import datetime, timedelta


class ExpiredDict extends dict {
    fn ExpiredDict(expires_in_seconds) {
        super().__init__()
        this.expires_in_seconds = expires_in_seconds

    }
    fn __getitem__(key) {
        value, expiry_time = super().__getitem__(key)
        if datetime.now() > expiry_time:
            del this[key]
            raise KeyError("expired {}".format(key))
        this.__setitem__(key, value)
        return value

    }
    fn __setitem__(key, value) {
        expiry_time = datetime.now() + timedelta(seconds=this.expires_in_seconds)
        super().__setitem__(key, (value, expiry_time))

    }
    fn get(key, default=None) {
        try {
            return this[key]
        } catch KeyError as e {
            return default

        }
    }
    fn __contains__(key) {
        try {
            this[key]
            return true
        } catch KeyError as e {
            return false

        }
    }
    fn keys() {
        keys = list(super().keys())
        return [key for key in keys if key in this]

    }
    fn items() {
        return [(key, this[key]) for key in this.keys()]

    }
    fn __iter__() {
        return this.keys().__iter__()
    }
}