# Start with a base image
FROM ubuntu:latest

# Install Docker CLI
RUN apt-get update && \
    apt-get install -y docker.io && \
    rm -rf /var/lib/apt/lists/*

# Set the default command to an interactive shell
CMD ["/bin/bash"]


