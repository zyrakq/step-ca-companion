FROM smallstep/step-cli:latest AS step
FROM nginxproxy/acme-companion:latest

# Copy step CLI from official image
COPY --from=step /usr/local/bin/step /usr/local/bin/

# Install additional dependencies for automation
RUN apk add --no-cache \
    curl \
    jq \
    bash \
    docker-cli

# Create directories for scripts
RUN mkdir -p /app/scripts

# Copy custom scripts and templates
COPY scripts/ /app/scripts/
COPY templates/ /app/templates/
COPY docker-gen.cfg /app/
COPY entrypoint.sh /app/

# Set execution permissions
RUN chmod +x /app/scripts/*.sh /app/entrypoint.sh

# Environment variables for step-ca (optional)
ENV STEP_CA_CONTAINER_NAME=""
ENV STEP_CA_URL=""
ENV STEP_CA_FINGERPRINT=""
ENV STEP_CA_BOOTSTRAP_TIMEOUT="300"

# Set custom entrypoint
ENTRYPOINT ["/app/entrypoint.sh"]