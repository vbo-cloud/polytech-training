FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src
COPY Worker.csproj .
RUN dotnet restore
COPY . .
RUN dotnet publish -o /app --self-contained false --no-restore

# The SDK image is only needed to compile. Worker.csproj is Microsoft.NET.Sdk
# with no ASP.NET package, and the /healthz listener is HttpListener from the
# BCL, so the plain runtime image is enough — 1.29GB down to roughly 220MB.
FROM mcr.microsoft.com/dotnet/runtime:8.0
WORKDIR /app
COPY --from=build /app .
ENTRYPOINT ["dotnet", "Worker.dll"]
