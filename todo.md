# Todo List: 

- [x]Handle Network Related Failures

JSON config loader
- [x] Site List
- [x] Options (port, timeouts, etc) -- only port is implemented so far

Notification System v1
- [x] Send external notifications when a site fails
- [x] Concrete Implementation with Discord Hooks
- [x] Move discord alert to its own struct
- [x] Failure Thresholds
- [ ] Repeat interval + never

Swap out print() for logging
- [ ] config destination via json
- [ ] swap all prints
- [ ] timestamps

Notification System v2
- [x] Event listener system
- [x] Abstract away so we can send notifications to anything

Async/Concurrency
- [ ] Event loop, coroutine based concurrent polling on a second thread
- [ ] Notification system on third thread
- [ ] Implement existing library or write our own?

Structured Logging System
- [ ] Time series?

