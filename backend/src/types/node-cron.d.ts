declare module "node-cron" {
  export interface ScheduledTask {
    start(): this;
    stop(): this;
    destroy(): void;
  }
  export function schedule(cronExpression: string, func: () => void | Promise<void>, options?: any): ScheduledTask;
  export function validate(cronExpression: string): boolean;
}
