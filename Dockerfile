# syntax=docker/dockerfile:1

# Comments are provided throughout this file to help you get started.
# If you need more help, visit the Dockerfile reference guide at
# https://docs.docker.com/go/dockerfile-reference/

# Want to help us make this template better? Share your feedback here: https://forms.gle/ybq9Krt8jtBL3iCk7

ARG RUST_VERSION=1.77.1
ARG PYTHON_VERSION=3.9.19
ARG APP_NAME=rs-py

################################################################################
# Create a stage for building the application.

FROM rust:${RUST_VERSION}-alpine AS rsbuild
ARG APP_NAME
WORKDIR /app

# Install host build dependencies.
RUN apk add --no-cache clang lld musl-dev git

# Build the application.
# Leverage a cache mount to /usr/local/cargo/registry/
# for downloaded dependencies, a cache mount to /usr/local/cargo/git/db
# for git repository dependencies, and a cache mount to /app/target/ for
# compiled dependencies which will speed up subsequent builds.
# Leverage a bind mount to the src directory to avoid having to copy the
# source code into the container. Once built, copy the executable to an
# output directory before the cache mounted /app/target is unmounted.
RUN --mount=type=bind,source=src,target=src \
    --mount=type=bind,source=Cargo.toml,target=Cargo.toml \
    --mount=type=bind,source=Cargo.lock,target=Cargo.lock \
    --mount=type=cache,target=/app/target/ \
    --mount=type=cache,target=/usr/local/cargo/git/db \
    --mount=type=cache,target=/usr/local/cargo/registry/ \
cargo build --locked --release && \
cp ./target/release/$APP_NAME /bin/server

################################################################################
# Create a new stage for running the application that contains the minimal
# runtime dependencies for the application. This often uses a different base
# image from the build stage where the necessary files are copied from the build
# stage.
#
# The example below uses the alpine image as the foundation for running the app.
# By specifying the "3.18" tag, it will use version 3.18 of alpine. If
# reproducability is important, consider using a digest
# (e.g., alpine@sha256:664888ac9cfd28068e062c991ebcff4b4c7307dc8dd4df9e728bedde5c449d91).

# build stage
FROM python:${PYTHON_VERSION}-slim as pybuild

WORKDIR /app
# install PDM
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install -U pdm
# disable update check
ENV PDM_CHECK_UPDATE=false
RUN --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    --mount=type=bind,source=pdm.lock,target=pdm.lock \
    pdm install --check --prod --no-editable


################################################################################
# run stage
FROM python:${PYTHON_VERSION}-slim as final

# Prevents Python from writing pyc files.
ENV PYTHONDONTWRITEBYTECODE=1

# Keeps Python from buffering stdout and stderr to avoid situations where
# the application crashes without emitting any logs due to buffering.
ENV PYTHONUNBUFFERED=1

WORKDIR /app

# Install Nginx
RUN apt-get update && apt-get install -y nginx

RUN --mount=type=cache,target=/root/.cache/pip \
    pip install -U supervisor

# # Create a non-privileged user that the app will run under.
# # See https://docs.docker.com/go/dockerfile-user-best-practices/
# ARG UID=10001
# RUN adduser \
#     --disabled-password \
#     --gecos "" \
#     --home "/nonexistent" \
#     --shell "/sbin/nologin" \
#     --no-create-home \
#     --uid "${UID}" \
#     appuser
# USER appuser

# retrieve packages from build stage
COPY --from=pybuild /app/.venv/ /app/.venv
ENV PATH="/app/.venv/bin:$PATH"
# Copy the source code into the container.
COPY . .
# Expose the port that the application listens on.
EXPOSE 8000
# Run the application.
# CMD ["fastapi", "run"]


# Copy the executable from the "build" stage.
COPY --from=rsbuild /bin/server /bin/

# Expose the port that the application listens on.
EXPOSE 3000

# What the container should run when it is started.
# CMD ["/bin/server"]


# Nginx
# RUN rm /etc/nginx/conf.d/default.conf
COPY nginx.conf /etc/nginx/nginx.conf
EXPOSE 3080

COPY supervisor.conf /app/supervisor.conf
CMD ["supervisord","-c","/app/supervisor.conf"]