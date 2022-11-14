# Use latest stable channel SDK.
FROM dart:stable AS build

# Resolve app dependencies.
WORKDIR /app
COPY . .
RUN dart pub get

# Copy app source code (except anything in .dockerignore) and AOT compile app.
RUN dart compile exe bin/pid.dart -o bin/pid

# Build minimal serving image from AOT-compiled `/pid`
# and the pre-built AOT-runtime in the `/runtime/` directory of the base image.
FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /app/bin/pid /app/bin/

# Start pid.
CMD ["/app/bin/pid"]
