# Queue module

Creates the encrypted inference queue and its dead-letter queue. The worker
uses long polling and only moves poison messages to the DLQ after bounded
retries.
