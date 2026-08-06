FROM mcr.microsoft.com/dotnet/sdk:8.0
WORKDIR /sources
COPY Worker.csproj .
RUN dotnet restore
COPY . .
RUN dotnet publish -o /app --self-contained false --no-restore
ENTRYPOINT ["dotnet", "/app/Worker.dll"]
