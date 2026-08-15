import logging
import time

logging.basicConfig(level=logging.INFO)


def main() -> None:
    logging.info("Worker started; connect SQS/EventBridge jobs in the AWS integration phase.")
    while True:
        time.sleep(60)


if __name__ == "__main__":
    main()

